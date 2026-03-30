/// Application entry point — spawns each service on its own tokio task.
#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let monitored = vec![std::path::PathBuf::from("/")];

    // start() scans, indexes, and returns RPC client handles
    let clients = store::start(monitored).await?;

    // ── monitor (not yet implemented) ─────────────────────────────────────────
    let _monitor_task = tokio::spawn(async move {
        let _for_monitor = clients.for_monitor;
        // TODO: monitor::start(for_monitor).await
    });

    // ── ui (not yet implemented) ──────────────────────────────────────────────
    let _ui_task = tokio::spawn(async move {
        let _for_ui = clients.for_ui;
        // TODO: ui::start(for_ui).await
    });

    std::future::pending::<()>().await;
    Ok(())
}
