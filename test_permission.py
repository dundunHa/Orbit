#!/usr/bin/env python3
"""Orbit Hook 权限请求测试 - 发送 PermissionRequest 并等待 UI 响应"""
import socket, json, time, sys

SOCKET_PATH = "/tmp/orbit.sock"

def send_event(payload, wait_response=False, timeout=60):
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.connect(SOCKET_PATH)
    msg = json.dumps(payload) + "\n"
    sock.sendall(msg.encode("utf-8"))
    event_name = payload.get("hook_event_name", "?")
    session_id = payload.get("session_id", "?")
    print(f"[发送] {event_name} (session={session_id})", flush=True)

    if wait_response:
        sock.settimeout(timeout)
        try:
            data = sock.recv(8192)
            response = data.decode("utf-8").strip()
            print(f"[响应] {response}", flush=True)
            return response
        except socket.timeout:
            print("[超时] 未收到响应", flush=True)
            return None
    else:
        sock.close()
        return None

SESSION_ID = "perm-test-" + str(int(time.time()))

# 1. SessionStart
send_event({
    "session_id": SESSION_ID,
    "hook_event_name": "SessionStart",
    "cwd": "/Users/lxp/test-project",
    "pid": 77777
})
time.sleep(0.5)

# 2. UserPromptSubmit
send_event({
    "session_id": SESSION_ID,
    "hook_event_name": "UserPromptSubmit",
    "cwd": "/Users/lxp/test-project",
    "message": "测试 Hook 权限请求"
})
time.sleep(0.5)

# 3. PermissionRequest - blocks until UI responds
print("\n=== 发送 PermissionRequest，请在 Orbit UI 上操作 (Allow/Deny) ===", flush=True)
resp = send_event({
    "session_id": SESSION_ID,
    "hook_event_name": "PermissionRequest",
    "cwd": "/Users/lxp/test-project",
    "tool_name": "Bash",
    "tool_input": {"command": "echo hello world", "description": "Print hello world"},
    "tool_use_id": "test-tool-" + str(int(time.time()))
}, wait_response=True, timeout=60)

if resp:
    print(f"\n=== 测试成功! 收到 UI 响应 ===", flush=True)
else:
    print(f"\n=== 测试完成 (无响应或超时) ===", flush=True)
