use crate::state::{Session, SessionStatus, SessionMap};
use tauri::{Emitter, Manager};

const ANOMALY_THRESHOLD_SECS: u64 = 60;
const CHECK_INTERVAL_SECS: u64 = 5;

pub async fn start(app_handle: tauri::AppHandle) {
    let mut interval = tokio::time::interval(std::time::Duration::from_secs(CHECK_INTERVAL_SECS));

    loop {
        interval.tick().await;

        let sessions_state: Option<tauri::State<'_, SessionMap>> =
            app_handle.try_state();
        let sessions_state = match sessions_state {
            Some(s) => s,
            None => continue,
        };

        // Collect updates while holding the lock, then emit after releasing
        let updates: Vec<Session> = {
            let mut sessions = sessions_state.lock().await;
            let now = chrono::Utc::now();
            let mut changed = Vec::new();

            for session in sessions.values_mut() {
                let delta = now.signed_duration_since(session.last_event_at);
                let idle_secs = delta.num_seconds().max(0) as u64;

                match &session.status {
                    SessionStatus::Processing | SessionStatus::RunningTool { .. } => {
                        if idle_secs >= ANOMALY_THRESHOLD_SECS {
                            session.status = SessionStatus::Anomaly {
                                idle_seconds: idle_secs,
                                previous_status: Box::new(session.status.clone()),
                            };
                            changed.push(session.clone());
                        }
                    }
                    SessionStatus::Anomaly { previous_status, .. } => {
                        session.status = SessionStatus::Anomaly {
                            idle_seconds: idle_secs,
                            previous_status: previous_status.clone(),
                        };
                        changed.push(session.clone());
                    }
                    _ => {}
                }
            }

            changed
        };

        for session in updates {
            let _ = app_handle.emit("session-update", session);
        }
    }
}
