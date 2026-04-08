use std::convert::Infallible;
use std::io::ErrorKind;
use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex as StdMutex};
use std::task::{Context as TaskContext, Poll};
use std::time::{Duration, Instant};

use anyhow::{Context as _, Result, anyhow, bail};
use buffa::MessageField;
use buffa::view::OwnedView;
use buffa_types::google::protobuf::Timestamp;
use connectrpc::client::{ClientConfig, Http2Connection, SharedHttp2Connection};
use connectrpc::{ConnectError, ConnectRpcService, Context, Router};
use futures::{Stream, stream};
use http::{Method, Response, StatusCode, Uri};
use http_body::{Body, Frame, SizeHint};
use hyper::service::service_fn;
use hyper_util::rt::{TokioExecutor, TokioIo};
use hyper_util::server::conn::auto::Builder as AutoBuilder;
use tokio::net::UnixListener;
use tokio::sync::Mutex as AsyncMutex;
use tower::Service;

use buffa_types::google::protobuf::EmptyView;

use crate::{
    data_dir,
    db::Database,
    proto::store::v1::{
        ConfigResponse, FileInfo, QueryRequestView, QueryResponse, StoreService,
        StoreServiceClient as GeneratedStoreServiceClient, StoreServiceExt as _,
        TreemapNode, TreemapNodeType, TreemapRequestView, TreemapResponse,
    },
    types::{FileEntry, TreemapNodeData, TreemapNodeKind},
};

const CLIENT_BUFFER_SIZE: usize = 1024;
const QUERY_RESPONSE_CHUNK_SIZE: usize = 256;
const STORE_SOCKET_NAME: &str = "store.sock";
const STORE_SOCKET_AUTHORITY: &str = "http://localhost";
static NEXT_REQUEST_ID: AtomicU64 = AtomicU64::new(1);

tokio::task_local! {
    static REQUEST_METRICS: Arc<StdMutex<RequestMetrics>>;
}

pub type StoreServiceClient = GeneratedStoreServiceClient<SharedHttp2Connection>;
type QueryResponseStream = Pin<Box<dyn Stream<Item = Result<QueryResponse, ConnectError>> + Send>>;

#[derive(Clone)]
pub struct StoreServer {
    db: Arc<AsyncMutex<Database>>,
}

pub struct StoreClients {
    pub for_ui: StoreServiceClient,
    pub for_monitor: StoreServiceClient,
}

#[derive(Clone, Copy, Default)]
struct QueryDbMetrics {
    pattern_len: usize,
    results: usize,
    total: Duration,
    db_lock_wait: Duration,
    duckdb_query: Duration,
    response_build: Duration,
}

#[derive(Default)]
struct RequestMetrics {
    request_id: u64,
    querydb: Option<QueryDbMetrics>,
}

struct RpcLogContext {
    request_id: u64,
    method: Method,
    path: String,
    status: StatusCode,
    request_started: Instant,
    request_metrics: Arc<StdMutex<RequestMetrics>>,
}

struct LoggedBody<B> {
    inner: B,
    rpc_log_context: Option<RpcLogContext>,
}

impl StoreServer {
    pub fn new(db: Arc<AsyncMutex<Database>>) -> Self {
        Self { db }
    }
}

impl StoreService for StoreServer {
    async fn querydb(
        &self,
        ctx: Context,
        req: OwnedView<QueryRequestView<'static>>,
    ) -> Result<(QueryResponseStream, Context), ConnectError> {
        let request_started = Instant::now();
        let pattern_len = req.pattern.chars().count();

        let lock_wait_started = Instant::now();
        let db = self.db.lock().await;
        let db_lock_wait = lock_wait_started.elapsed();

        if db.is_indexing().unwrap_or(false) {
            return Err(ConnectError::failed_precondition("indexing in progress"));
        }

        let query_started = Instant::now();
        let files = match db.query_files(req.pattern) {
            Ok(files) => files,
            Err(err) => {
                record_querydb_metrics(QueryDbMetrics {
                    pattern_len,
                    results: 0,
                    total: request_started.elapsed(),
                    db_lock_wait,
                    duckdb_query: query_started.elapsed(),
                    response_build: Duration::ZERO,
                });
                return Err(internal_error(err));
            }
        };
        let duckdb_query = query_started.elapsed();

        let response_build_started = Instant::now();
        let results = files.len();
        let response_stream = query_response_stream(files);
        let response_build = response_build_started.elapsed();
        let total = request_started.elapsed();

        record_querydb_metrics(QueryDbMetrics {
            pattern_len,
            results,
            total,
            db_lock_wait,
            duckdb_query,
            response_build,
        });

        Ok((response_stream, ctx))
    }

    async fn getconfig(
        &self,
        ctx: Context,
        _req: OwnedView<EmptyView<'static>>,
    ) -> Result<(ConfigResponse, Context), ConnectError> {
        let db = self.db.lock().await;
        let row = db.get_config().map_err(internal_error)?;
        let response = ConfigResponse {
            version: row.version,
            exclude: row.exclude,
            last_indexed: row
                .last_indexed_secs
                .map(|secs| buffa::MessageField::some(buffa_types::google::protobuf::Timestamp {
                    seconds: secs,
                    nanos: 0,
                    ..Default::default()
                }))
                .unwrap_or_default(),
            total_files: row.total_files,
            indexing: row.indexing,
            monitoring: row.monitoring,
            ..Default::default()
        };
        Ok((response, ctx))
    }

    async fn gettreemap(
        &self,
        ctx: Context,
        req: OwnedView<TreemapRequestView<'static>>,
    ) -> Result<(TreemapResponse, Context), ConnectError> {
        let db = self.db.lock().await;

        if db.is_indexing().unwrap_or(false) {
            return Err(ConnectError::failed_precondition("indexing in progress"));
        }

        let root = db.get_treemap(req.root_path, req.depth).map_err(internal_error)?;
        let response = TreemapResponse {
            root: MessageField::some(treemap_node_to_proto(root)),
            ..Default::default()
        };

        Ok((response, ctx))
    }
}

pub fn socket_path() -> Result<PathBuf> {
    Ok(data_dir()?.join(STORE_SOCKET_NAME))
}

pub async fn spawn_server(server: StoreServer, socket_path: PathBuf) -> Result<StoreClients> {
    let listener = bind_uds_listener(&socket_path)?;
    let service = Arc::new(server).register(Router::new());
    let server_task = tokio::spawn(run_uds_server(listener, ConnectRpcService::new(service)));

    let transport = Http2Connection::connect_unix(&socket_path, socket_authority()?)
        .await
        .map_err(|err| {
            anyhow!(
                "failed to connect to store UDS {}: {err}",
                socket_path.display()
            )
        })?
        .shared(CLIENT_BUFFER_SIZE);
    let config = ClientConfig::new(socket_authority()?);

    let clients = StoreClients {
        for_ui: StoreServiceClient::new(transport.clone(), config.clone()),
        for_monitor: StoreServiceClient::new(transport, config),
    };

    tokio::spawn(async move {
        if let Err(err) = server_task.await {
            eprintln!("[store] rpc server task failed: {err}");
        }
    });

    Ok(clients)
}

fn bind_uds_listener(socket_path: &Path) -> Result<UnixListener> {
    if let Some(parent) = socket_path.parent() {
        std::fs::create_dir_all(parent).with_context(|| {
            format!("failed to create rpc socket directory {}", parent.display())
        })?;
    }

    match std::fs::symlink_metadata(socket_path) {
        Ok(metadata) => {
            #[cfg(unix)]
            {
                use std::os::unix::fs::FileTypeExt;

                if metadata.file_type().is_socket() {
                    std::fs::remove_file(socket_path).with_context(|| {
                        format!(
                            "failed to remove stale rpc socket {}",
                            socket_path.display()
                        )
                    })?;
                } else {
                    bail!(
                        "refusing to replace non-socket path at {}",
                        socket_path.display()
                    );
                }
            }
        }
        Err(err) if err.kind() == ErrorKind::NotFound => {}
        Err(err) => {
            return Err(err).with_context(|| {
                format!(
                    "failed to inspect rpc socket path {}",
                    socket_path.display()
                )
            });
        }
    }

    UnixListener::bind(socket_path)
        .with_context(|| format!("failed to bind rpc socket {}", socket_path.display()))
}

async fn run_uds_server(listener: UnixListener, service: ConnectRpcService) -> Result<()> {
    loop {
        let (stream, _) = listener
            .accept()
            .await
            .context("failed to accept UDS connection")?;
        let rpc_service = service.clone();

        tokio::spawn(async move {
            let connection_service = service_fn(move |req| {
                let mut rpc_service = rpc_service.clone();
                let method = req.method().clone();
                let path = req.uri().path().to_owned();
                let request_started = Instant::now();
                let request_id = NEXT_REQUEST_ID.fetch_add(1, Ordering::Relaxed);
                let request_metrics = Arc::new(StdMutex::new(RequestMetrics::new(request_id)));

                async move {
                    REQUEST_METRICS
                        .scope(Arc::clone(&request_metrics), async move {
                            let response = rpc_service.call(req).await?;
                            let status = response.status();
                            let response = wrap_response_body(
                                response,
                                RpcLogContext {
                                    request_id,
                                    method,
                                    path,
                                    status,
                                    request_started,
                                    request_metrics,
                                },
                            );
                            Ok::<_, Infallible>(response)
                        })
                        .await
                }
            });

            let mut builder = AutoBuilder::new(TokioExecutor::new());
            builder.http1().keep_alive(true);

            if let Err(err) = builder
                .serve_connection(TokioIo::new(stream), connection_service)
                .await
            {
                if !is_benign_connection_error(err.as_ref()) {
                    eprintln!("[store] rpc connection error: {err}");
                }
            }
        });
    }
}

fn file_entry_to_proto(entry: FileEntry) -> FileInfo {
    FileInfo {
        name: entry.name,
        path: entry.path,
        size: entry.size.try_into().unwrap_or(i64::MAX),
        modified: timestamp_from_unix_seconds(&entry.change_time),
        ..Default::default()
    }
}

fn query_response_stream(files: Vec<FileEntry>) -> QueryResponseStream {
    let responses = files
        .chunks(QUERY_RESPONSE_CHUNK_SIZE)
        .map(|chunk| {
            Ok(QueryResponse {
                files: chunk.iter().cloned().map(file_entry_to_proto).collect(),
                ..Default::default()
            })
        })
        .collect::<Vec<_>>();
    Box::pin(stream::iter(responses))
}

fn timestamp_from_unix_seconds(raw: &str) -> MessageField<Timestamp> {
    raw.parse::<i64>()
        .ok()
        .filter(|seconds| *seconds > 0)
        .map(|seconds| {
            MessageField::some(Timestamp {
                seconds,
                nanos: 0,
                ..Default::default()
            })
        })
        .unwrap_or_default()
}

fn treemap_node_to_proto(node: TreemapNodeData) -> TreemapNode {
    let node_type = match node.kind {
        TreemapNodeKind::File => TreemapNodeType::FILE,
        TreemapNodeKind::Directory => TreemapNodeType::DIRECTORY,
    };

    TreemapNode {
        path: node.path,
        name: node.name,
        r#type: node_type.into(),
        size: node.size.try_into().unwrap_or(i64::MAX),
        has_children: node.has_children,
        children: node
            .children
            .into_iter()
            .map(treemap_node_to_proto)
            .collect(),
        ..Default::default()
    }
}

fn socket_authority() -> Result<Uri> {
    STORE_SOCKET_AUTHORITY
        .parse()
        .map_err(|err| anyhow!("invalid store socket authority {STORE_SOCKET_AUTHORITY}: {err}"))
}

fn internal_error(err: impl std::fmt::Display) -> ConnectError {
    ConnectError::internal(format!("store query failed: {err}"))
}

impl RequestMetrics {
    fn new(request_id: u64) -> Self {
        Self {
            request_id,
            querydb: None,
        }
    }
}

impl<B> LoggedBody<B> {
    fn new(inner: B, rpc_log_context: RpcLogContext) -> Self {
        Self {
            inner,
            rpc_log_context: Some(rpc_log_context),
        }
    }

    fn emit_rpc_log(&mut self) {
        let Some(rpc_log_context) = self.rpc_log_context.take() else {
            return;
        };

        let total = rpc_log_context.request_started.elapsed();
        let querydb = querydb_metrics_snapshot(&rpc_log_context.request_metrics);
        log_rpc_request(
            rpc_log_context.request_id,
            &rpc_log_context.method,
            &rpc_log_context.path,
            rpc_log_context.status,
            total,
            querydb,
        );
    }
}

impl<B> Body for LoggedBody<B>
where
    B: Body + Unpin,
{
    type Data = B::Data;
    type Error = B::Error;

    fn poll_frame(
        mut self: Pin<&mut Self>,
        cx: &mut TaskContext<'_>,
    ) -> Poll<Option<Result<Frame<Self::Data>, Self::Error>>> {
        match Pin::new(&mut self.inner).poll_frame(cx) {
            Poll::Ready(None) => {
                self.emit_rpc_log();
                Poll::Ready(None)
            }
            Poll::Ready(Some(frame)) => Poll::Ready(Some(frame)),
            Poll::Pending => Poll::Pending,
        }
    }

    fn is_end_stream(&self) -> bool {
        self.inner.is_end_stream()
    }

    fn size_hint(&self) -> SizeHint {
        self.inner.size_hint()
    }
}

fn record_querydb_metrics(metrics: QueryDbMetrics) {
    let request_id = REQUEST_METRICS
        .try_with(|request_metrics| {
            let mut state = lock_request_metrics(request_metrics);
            state.querydb = Some(metrics);
            state.request_id
        })
        .ok()
        .unwrap_or(0);

    log_querydb_request(request_id, metrics);
}

fn querydb_metrics_snapshot(request_metrics: &Arc<StdMutex<RequestMetrics>>) -> Option<QueryDbMetrics> {
    lock_request_metrics(request_metrics).querydb
}

fn wrap_response_body<B>(
    response: Response<B>,
    rpc_log_context: RpcLogContext,
) -> Response<LoggedBody<B>> {
    let (parts, body) = response.into_parts();
    Response::from_parts(parts, LoggedBody::new(body, rpc_log_context))
}

fn lock_request_metrics(
    request_metrics: &Arc<StdMutex<RequestMetrics>>,
) -> std::sync::MutexGuard<'_, RequestMetrics> {
    request_metrics
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn log_querydb_request(request_id: u64, metrics: QueryDbMetrics) {
    println!(
        "[store][req {request_id}] querydb pattern_len={} results={} total={} db_lock_wait={} duckdb_query={} response_build={} handler_elapsed={}",
        metrics.pattern_len,
        metrics.results,
        format_duration(metrics.total),
        format_duration(metrics.db_lock_wait),
        format_duration(metrics.duckdb_query),
        format_duration(metrics.response_build),
        format_duration(metrics.total),
    );
}

fn log_rpc_request(
    request_id: u64,
    method: &Method,
    path: &str,
    status: StatusCode,
    total: Duration,
    querydb: Option<QueryDbMetrics>,
) {
    if let Some(metrics) = querydb {
        let transport_overhead = total.saturating_sub(metrics.total);
        println!(
            "[store][req {request_id}] rpc {method} {path} status={status} total={} transport_overhead={} handler={} duckdb_query={} db_lock_wait={} response_build={} results={} pattern_len={}",
            format_duration(total),
            format_duration(transport_overhead),
            format_duration(metrics.total),
            format_duration(metrics.duckdb_query),
            format_duration(metrics.db_lock_wait),
            format_duration(metrics.response_build),
            metrics.results,
            metrics.pattern_len,
        );
    } else {
        println!(
            "[store][req {request_id}] rpc {method} {path} status={status} total={}",
            format_duration(total),
        );
    }
}

fn format_duration(duration: Duration) -> String {
    let seconds = duration.as_secs_f64();
    if seconds >= 1.0 {
        format!("{seconds:.2}s")
    } else if seconds >= 0.001 {
        format!("{:.2}ms", seconds * 1_000.0)
    } else if seconds >= 0.000_001 {
        format!("{:.2}us", seconds * 1_000_000.0)
    } else {
        format!("{}ns", duration.as_nanos())
    }
}

fn is_benign_connection_error(err: &(dyn std::error::Error + 'static)) -> bool {
    err.downcast_ref::<hyper::Error>()
        .is_some_and(|err| err.is_shutdown() || err.is_body_write_aborted())
        || err
            .downcast_ref::<std::io::Error>()
            .is_some_and(is_benign_io_error)
        || err.source().is_some_and(is_benign_connection_error)
}

fn is_benign_io_error(err: &std::io::Error) -> bool {
    matches!(
        err.kind(),
        std::io::ErrorKind::BrokenPipe
            | std::io::ErrorKind::ConnectionAborted
            | std::io::ErrorKind::ConnectionReset
            | std::io::ErrorKind::NotConnected
            | std::io::ErrorKind::UnexpectedEof
    )
}
