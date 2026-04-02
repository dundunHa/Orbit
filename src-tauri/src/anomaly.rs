use crate::state::SessionStatus;
use tauri::{Emitter, Manager};

const ANOMALY_THRESHOLD_SECS: u64 = 60;
const CHECK_INTERVAL_SECS: u64 = 5;

pub async fn start(app_handle: tauri::AppHandle) {
    let mut interval = tokio::time::interval(std::time::Duration::from_secs(CHECK_INTERVAL_SECS));

    loop {
        interval.tick().await;

        let sessions: Option<tauri::State<'_, crate::state::SessionMap>> =
            app_handle.try_state();
        let sessions = match sessions {
            Some(s) => s,
            None => continue,
        };

        let mut sessions = sessions.lock().await;
        let now = chrono::Utc::now();

        for session in sessions.values_mut() {
            let idle_secs = (now - session.last_event_at).num_seconds().max(0) as u64;

            match &session.status {
                SessionStatus::Processing | SessionStatus::RunningTool { .. } => {
                    if idle_secs >= ANOMALY_THRESHOLD_SECS {
                        session.status = SessionStatus::Anomaly {
                            idle_seconds: idle_secs,
                            previous_status: Box::new(session.status.clone()),
                        };
                        let _ = app_handle.emit("session-update", session.clone());
                    }
                }
                SessionStatus::Anomaly { .. } => {
                    // Update idle time
                    session.status = SessionStatus::Anomaly {
                        idle_seconds: idle_secs,
                        previous_status: match &session.status {
                            SessionStatus::Anomaly {
                                previous_status, ..
                            } => previous_status.clone(),
                            _ => Box::new(SessionStatus::Processing),
                        },
                    };
                    let _ = app_handle.emit("session-update", session.clone());
                }
                _ => {}
            }
        }
    }
}
