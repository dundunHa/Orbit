#!/bin/bash
# Orbit Hook 模拟测试脚本
# 用法: ./test_hooks.sh [事件名称]
# 不带参数则运行完整流程

SOCKET="/tmp/orbit.sock"
SESSION_ID="test-session-$(date +%s)"
CWD="/Users/lxp/test-project"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

send_event() {
    local name="$1"
    local json="$2"
    echo -e "${CYAN}>>> 发送事件: ${name}${NC}"
    echo "$json" | nc -U -w 2 "$SOCKET"
    local rc=$?
    if [ $rc -eq 0 ]; then
        echo -e "${GREEN}    OK${NC}"
    else
        echo -e "${RED}    FAIL (rc=$rc)${NC}"
    fi
    sleep 1
}

send_event_with_response() {
    local name="$1"
    local json="$2"
    echo -e "${YELLOW}>>> 发送事件 (等待响应): ${name}${NC}"
    echo -e "${YELLOW}    请在 Orbit 界面上操作 (Allow/Deny)...${NC}"
    local response
    response=$(echo "$json" | nc -U "$SOCKET")
    if [ -n "$response" ]; then
        echo -e "${GREEN}    响应: ${response}${NC}"
    else
        echo -e "${RED}    无响应${NC}"
    fi
}

# --- 事件定义 (单行 JSON，SocketServer 以换行分隔消息) ---

event_session_start() {
    send_event "SessionStart" '{"session_id":"'"$SESSION_ID"'","hook_event_name":"SessionStart","cwd":"'"$CWD"'","pid":12345,"tty":"/dev/ttys001"}'
}

event_user_prompt() {
    send_event "UserPromptSubmit" '{"session_id":"'"$SESSION_ID"'","hook_event_name":"UserPromptSubmit","cwd":"'"$CWD"'","message":"帮我修复登录页面的 bug"}'
}

event_pre_tool_use() {
    local tool="${1:-Read}"
    send_event "PreToolUse ($tool)" '{"session_id":"'"$SESSION_ID"'","hook_event_name":"PreToolUse","cwd":"'"$CWD"'","tool_name":"'"$tool"'","tool_input":{"file_path":"/src/login.swift"},"tool_use_id":"tool-'"$(date +%s%N)"'"}'
}

event_post_tool_use() {
    send_event "PostToolUse" '{"session_id":"'"$SESSION_ID"'","hook_event_name":"PostToolUse","cwd":"'"$CWD"'","tool_name":"Read","tool_use_id":"tool-done-1"}'
}

event_permission_request() {
    local tool="${1:-Bash}"
    send_event_with_response "PermissionRequest ($tool)" '{"session_id":"'"$SESSION_ID"'","hook_event_name":"PermissionRequest","cwd":"'"$CWD"'","tool_name":"'"$tool"'","tool_input":{"command":"rm -rf /tmp/test"},"tool_use_id":"perm-'"$(date +%s)"'"}'
}

event_stop() {
    send_event "Stop" '{"session_id":"'"$SESSION_ID"'","hook_event_name":"Stop","cwd":"'"$CWD"'"}'
}

event_session_end() {
    send_event "SessionEnd" '{"session_id":"'"$SESSION_ID"'","hook_event_name":"SessionEnd","cwd":"'"$CWD"'"}'
}

event_statusline() {
    send_event "StatuslineUpdate" '{"type":"StatuslineUpdate","session_id":"'"$SESSION_ID"'","tokens_in":15000,"tokens_out":3200,"cost_usd":0.0842,"model":"claude-opus-4-6-v1"}'
}

event_notification() {
    send_event "Notification" '{"session_id":"'"$SESSION_ID"'","hook_event_name":"Notification","cwd":"'"$CWD"'","notification_type":"idle_prompt","message":"Claude 正在等待输入..."}'
}

event_pre_compact() {
    send_event "PreCompact" '{"session_id":"'"$SESSION_ID"'","hook_event_name":"PreCompact","cwd":"'"$CWD"'"}'
}

event_subagent_stop() {
    send_event "SubagentStop" '{"session_id":"'"$SESSION_ID"'","hook_event_name":"SubagentStop","cwd":"'"$CWD"'"}'
}

# --- 运行逻辑 ---

case "${1:-full}" in
    full)
        echo -e "${CYAN}=== Orbit Hook 完整流程测试 ===${NC}"
        echo -e "${CYAN}Session ID: $SESSION_ID${NC}"
        echo ""
        event_session_start
        event_statusline
        event_user_prompt
        event_pre_tool_use "Read" "Reading file"
        event_post_tool_use
        event_pre_tool_use "Edit" "Editing file"
        event_post_tool_use
        event_stop
        event_session_end
        echo -e "\n${GREEN}=== 完整流程测试完成 ===${NC}"
        ;;
    permission)
        echo -e "${YELLOW}=== Permission Request 测试 ===${NC}"
        echo -e "${CYAN}Session ID: $SESSION_ID${NC}"
        echo ""
        event_session_start
        event_user_prompt
        event_permission_request "${2:-Bash}"
        echo -e "\n${GREEN}=== Permission 测试完成 ===${NC}"
        ;;
    start)
        event_session_start
        ;;
    prompt)
        event_session_start
        event_user_prompt
        ;;
    tool)
        event_session_start
        event_user_prompt
        event_pre_tool_use "${2:-Read}"
        ;;
    compact)
        event_session_start
        event_user_prompt
        event_pre_compact
        ;;
    status|statusline)
        event_session_start
        event_statusline
        ;;
    notify|notification)
        event_session_start
        event_notification
        ;;
    end)
        event_session_start
        event_session_end
        ;;
    *)
        echo "用法: $0 [full|permission|start|prompt|tool|compact|statusline|notification|end]"
        echo ""
        echo "  full         完整生命周期 (默认)"
        echo "  permission   测试权限请求 (会等待 UI 操作)"
        echo "  start        仅 SessionStart"
        echo "  prompt       SessionStart + UserPromptSubmit"
        echo "  tool [名称]  SessionStart + Prompt + PreToolUse"
        echo "  compact      测试 PreCompact"
        echo "  statusline   测试 StatuslineUpdate"
        echo "  notification 测试 Notification"
        echo "  end          SessionStart + SessionEnd"
        exit 1
        ;;
esac
