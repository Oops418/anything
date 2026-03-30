use std::sync::Arc;

use futures::prelude::*;
use tarpc::{
    client, context,
    server::{self, Channel},
};
use tokio::sync::Mutex;

use crate::{
    db::Database,
    types::{
        ModifyDirection, ModifyRequest, ModifyResponse, QueryRequest, QueryResponse, QueryWay,
    },
};

// ── service definition ───────────────────────────────────────────────────────

/// tarpc service — one interface covers both UI queries and monitor updates.
///
/// UI sends:      `QueryRequest  { way: DuckDb, pattern: "..." }`
/// Monitor sends: `ModifyRequest { direction: Insert|Delete|Change, data: FileEntry }`
#[tarpc::service]
pub trait StoreService {
    async fn query(req: QueryRequest) -> QueryResponse;
    async fn modify(req: ModifyRequest) -> ModifyResponse;
}

// ── server implementation ────────────────────────────────────────────────────

#[derive(Clone)]
pub struct StoreServer {
    db: Arc<Mutex<Database>>,
}

impl StoreServer {
    pub fn new(db: Arc<Mutex<Database>>) -> Self {
        Self { db }
    }
}

impl StoreService for StoreServer {
    async fn query(self, _: context::Context, req: QueryRequest) -> QueryResponse {
        let pattern = match req.way {
            QueryWay::DuckDb => req.pattern,
        };

        let db = self.db.lock().await;
        match db.query_files(&pattern) {
            Ok(files) => QueryResponse { files },
            Err(e) => {
                eprintln!("[store] query error: {e}");
                QueryResponse { files: vec![] }
            }
        }
    }

    async fn modify(self, _: context::Context, req: ModifyRequest) -> ModifyResponse {
        let db = self.db.lock().await;
        let result = match req.direction {
            ModifyDirection::Insert | ModifyDirection::Change => db.upsert_file(&req.data),
            ModifyDirection::Delete => db.delete_file(&req.data.path),
        };

        match result {
            Ok(_) => ModifyResponse { success: true },
            Err(e) => {
                eprintln!("[store] modify error: {e}");
                ModifyResponse { success: false }
            }
        }
    }
}

// ── in-process channel wiring ────────────────────────────────────────────────

/// Client handles returned to the entry crate.
/// `for_ui` and `for_monitor` are independent in-process channels to the same
/// store server so UI and monitor can call RPC concurrently without TCP overhead.
pub struct StoreClients {
    pub for_ui: StoreServiceClient,
    pub for_monitor: StoreServiceClient,
}

/// Create an in-process channel pair, spawn the server half, and return the client.
fn make_client(s: StoreServer) -> StoreServiceClient {
    let (client_transport, server_transport) = tarpc::transport::channel::unbounded();
    let channel = server::BaseChannel::with_defaults(server_transport);
    tokio::spawn(
        channel
            .execute(s.serve())
            .for_each(|response| async move { tokio::spawn(response); }),
    );
    StoreServiceClient::new(client::Config::default(), client_transport).spawn()
}

/// Spawn two independent in-process server tasks and return matching client stubs.
pub fn spawn_server(server: StoreServer) -> StoreClients {
    StoreClients {
        for_ui: make_client(server.clone()),
        for_monitor: make_client(server),
    }
}
