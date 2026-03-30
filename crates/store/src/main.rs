/// Standalone store binary for development / testing.
/// Scans $HOME, starts the in-process RPC server, and waits.
#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let _clients = store::start(vec![std::path::PathBuf::from("/")]).await?;

    println!("[store] ready");
    std::future::pending::<()>().await;
    Ok(())
}
