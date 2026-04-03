use std::io::ErrorKind;
use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::sync::Arc;

use anyhow::{Context as _, Result, anyhow, bail};
use buffa::MessageField;
use buffa::view::OwnedView;
use buffa_types::google::protobuf::Timestamp;
use connectrpc::client::{ClientConfig, Http2Connection, SharedHttp2Connection};
use connectrpc::{ConnectError, ConnectRpcService, Context, Router};
use futures::{Stream, stream};
use http::Uri;
use hyper::service::service_fn;
use hyper_util::rt::{TokioExecutor, TokioIo};
use hyper_util::server::conn::auto::Builder as AutoBuilder;
use tokio::net::UnixListener;
use tokio::sync::Mutex;
use tower::Service;

use crate::{
    data_dir,
    db::Database,
    proto::store::v1::{
        FileInfo, QueryRequestView, QueryResponse, StoreService,
        StoreServiceClient as GeneratedStoreServiceClient, StoreServiceExt as _,
    },
    types::FileEntry,
};

const CLIENT_BUFFER_SIZE: usize = 1024;
const QUERY_RESPONSE_CHUNK_SIZE: usize = 256;
const STORE_SOCKET_NAME: &str = "store.sock";
const STORE_SOCKET_AUTHORITY: &str = "http://localhost";

pub type StoreServiceClient = GeneratedStoreServiceClient<SharedHttp2Connection>;
type QueryResponseStream = Pin<Box<dyn Stream<Item = Result<QueryResponse, ConnectError>> + Send>>;

#[derive(Clone)]
pub struct StoreServer {
    db: Arc<Mutex<Database>>,
}

pub struct StoreClients {
    pub for_ui: StoreServiceClient,
    pub for_monitor: StoreServiceClient,
}

impl StoreServer {
    pub fn new(db: Arc<Mutex<Database>>) -> Self {
        Self { db }
    }
}

impl StoreService for StoreServer {
    async fn querydb(
        &self,
        ctx: Context,
        req: OwnedView<QueryRequestView<'static>>,
    ) -> Result<(QueryResponseStream, Context), ConnectError> {
        let db = self.db.lock().await;
        let files = db.query_files(req.pattern).map_err(internal_error)?;

        Ok((query_response_stream(files), ctx))
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
                async move { rpc_service.call(req).await }
            });

            let mut builder = AutoBuilder::new(TokioExecutor::new());
            builder.http1().keep_alive(true);

            if let Err(err) = builder
                .serve_connection(TokioIo::new(stream), connection_service)
                .await
            {
                eprintln!("[store] rpc connection error: {err}");
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

fn socket_authority() -> Result<Uri> {
    STORE_SOCKET_AUTHORITY
        .parse()
        .map_err(|err| anyhow!("invalid store socket authority {STORE_SOCKET_AUTHORITY}: {err}"))
}

fn internal_error(err: impl std::fmt::Display) -> ConnectError {
    ConnectError::internal(format!("store query failed: {err}"))
}
