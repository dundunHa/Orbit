const feedback = document.getElementById("feedback");
const openSettingsButton = document.getElementById("open-settings");
const copyCommandButton = document.getElementById("copy-command");
const { invoke } = window.__TAURI__.core;

function setFeedback(message, isError = false) {
  feedback.textContent = message;
  feedback.classList.toggle("error", isError);
}

openSettingsButton.addEventListener("click", async () => {
  try {
    await invoke("open_system_settings");
    setFeedback("系统设置已打开。授予权限后返回 Orbit。", false);
  } catch (error) {
    console.error("Failed to open System Settings", error);
    setFeedback(String(error), true);
  }
});

copyCommandButton.addEventListener("click", async () => {
  try {
    const command = await invoke("copy_permission_cli_command");
    setFeedback(`已复制命令：${command}`, false);
  } catch (error) {
    console.error("Failed to copy CLI command", error);
    setFeedback(String(error), true);
  }
});
