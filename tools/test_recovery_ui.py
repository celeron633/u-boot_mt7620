"""Browser checks against generated fsdata.c, with mocked device operations.

Requires Playwright and Chromium. Run after build-wsl.sh:
  python tools/test_recovery_ui.py --screenshots /tmp/recovery-preview
The test never connects to a router and never writes device flash.
"""
import argparse
import json
import re
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parent.parent
INFO = {"model": "HC5761", "ram": 128 << 20, "flash": 16 << 20,
        "firmware_limit": 0xf70000, "firmware_offset": 0x50000,
        "bootloader": 0x30000}


def embedded_files():
    source = (ROOT / "httpd/fsdata.c").read_text()
    files = {}
    for name, encoded in re.findall(
            r"static const char data_(\w+)\[\] = \{(.*?)\};", source, re.S):
        stem, extension = name.rsplit("_", 1)
        files["/" + stem + "." + extension] = bytes(
            int(value, 16) for value in re.findall(r"0x([0-9a-fA-F]{2})", encoded))
    assert b"application/javascript" in files["/main.js"].split(b"\r\n\r\n")[0]
    assert b"--sidebar-bg" in files["/style.css"]
    return files


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--screenshots", type=Path)
    args = parser.parse_args()
    files = embedded_files()
    requests = []

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            requests.append(("GET", self.path, b""))
            if self.path == "/sysinfo":
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps(INFO).encode())
            elif self.path == "/backup.bin":
                self.send_response(200)
                self.send_header("Content-Type", "application/octet-stream")
                self.send_header("Content-Disposition", "attachment; filename=flash-backup.bin")
                self.send_header("Content-Length", str(INFO["flash"]))
                self.end_headers()
                self.wfile.write(b"\xff" * INFO["flash"])
            else:
                self.wfile.write(files.get("/index.html" if self.path == "/" else self.path,
                                           files["/404.html"]))

        def do_POST(self):
            body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
            requests.append(("POST", self.path, body))
            if self.path == "/reboot":
                response = "rebooting.html"
            elif self.path == "/env_reset":
                response = "env_reset_ok.html"
            else:
                assert b'name="firmware"' in body
                response = "flashing.html"
            self.wfile.write(files["/" + response])

        def log_message(self, *args):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    url = "http://127.0.0.1:" + str(server.server_port)
    errors = []
    try:
        with sync_playwright() as p:
            browser = p.chromium.launch(headless=True)
            context = browser.new_context(locale="zh-CN", accept_downloads=True)
            page = context.new_page()
            page.on("pageerror", lambda error: errors.append(str(error)))
            page.set_viewport_size({"width": 1280, "height": 900})
            page.goto(url)
            page.locator(".sysinfo-main").wait_for()
            assert "HC5761" in page.locator("#sysinfo").inner_text()
            assert page.locator(".app-nav a").count() == 4
            assert page.locator(".app-sidebar").bounding_box()["width"] == 260
            assert page.locator("h1").inner_text() == "固件升级"
            assert not page.locator('a[href="/uboot.html"], a[href="/initramfs.html"], a[href="/factory.html"]').count()
            if args.screenshots:
                args.screenshots.mkdir(parents=True, exist_ok=True)
                page.screenshot(path=str(args.screenshots / "firmware-desktop.png"), full_page=True)
            page.locator("#theme").select_option("dark")
            assert page.locator("html").get_attribute("data-theme") == "dark"
            page.locator("#language").select_option("en")
            assert page.locator("h1").inner_text() == "Firmware update"
            page.locator('nav a[href="/backup.html"]').click()
            page.locator(".sysinfo-main").wait_for()
            assert page.locator("h1").inner_text() == "Backup"
            assert page.locator("html").get_attribute("data-theme") == "dark"
            assert "16777216" in page.locator("#backup-size").inner_text()
            with page.expect_download() as download_event:
                page.locator("#download").click()
            download = download_event.value
            assert download.suggested_filename == "flash-backup.bin"
            assert not download.failure()
            assert Path(download.path()).stat().st_size == INFO["flash"]
            page.locator("#language").select_option("zh")
            assert "浏览器" in page.locator("#backup-status").inner_text()
            if args.screenshots:
                page.screenshot(path=str(args.screenshots / "backup-dark.png"), full_page=True)
            page.locator('nav a[href="/reboot.html"]').click()
            assert not any(method == "POST" and path == "/reboot" for method, path, _ in requests)
            page.once("dialog", lambda dialog: dialog.dismiss())
            page.get_by_role("button", name="立即重启").click()
            assert not any(method == "POST" and path == "/reboot" for method, path, _ in requests)
            checkpoint = len(requests)
            page.once("dialog", lambda dialog: dialog.accept())
            page.get_by_role("button", name="立即重启").click()
            page.wait_for_url(url + "/reboot")
            assert page.locator("h1").inner_text() == "设备正在重启"
            assert [(method, path) for method, path, _ in requests[checkpoint:]] == [("POST", "/reboot")]
            page.goto(url)
            page.locator(".sysinfo-main").wait_for()
            page.set_input_files("#file", {"name": "test.bin", "mimeType": "application/octet-stream", "buffer": b"x" * 12288})
            page.once("dialog", lambda dialog: dialog.accept())
            checkpoint = len(requests)
            page.get_by_role("button", name="上传并更新").click()
            page.wait_for_load_state("load")
            assert page.locator("h1").inner_text() == "更新进行中"
            assert [(method, path) for method, path, _ in requests[checkpoint:]] == [("POST", "/")]
            page.goto(url + "/environment.html")
            page.once("dialog", lambda dialog: dialog.accept())
            page.get_by_role("button", name="恢复默认环境").click()
            page.wait_for_url(url + "/env_reset")
            assert page.locator("h1").inner_text() == "环境已恢复"
            for filename in ("fail.html", "firmware_too_big.html", "env_reset_fail.html", "404.html"):
                page.goto(url + "/" + filename)
                assert page.locator(".app-nav a").count() == 4
                assert page.locator("h1.red").is_visible()
            page.goto(url)
            page.locator("#theme").select_option("light")
            page.set_viewport_size({"width": 390, "height": 844})
            assert page.evaluate("document.documentElement.scrollWidth <= innerWidth")
            assert page.locator(".app-sidebar").bounding_box()["y"] < page.locator("#m").bounding_box()["y"]
            if args.screenshots:
                page.screenshot(path=str(args.screenshots / "firmware-mobile.png"), full_page=True)
            no_js = browser.new_context(java_script_enabled=False)
            plain = no_js.new_page()
            plain.goto(url)
            assert plain.locator('form[method="post"] input[name="firmware"]').count() == 1
            plain.goto(url + "/backup.html")
            assert plain.locator('a[href="/backup.bin"]').is_visible()
            plain.goto(url + "/reboot.html")
            assert plain.locator('form[method="post"][action="/reboot"]').is_visible()
            browser.close()
            assert not errors, errors
    finally:
        server.shutdown()
        server.server_close()
    print("PASS: embedded HTML/CSS/JS, desktop/mobile, theme/language persistence, full backup download, POST reboot/confirmation, firmware upload, environment reset, error pages and no-JS forms")


if __name__ == "__main__":
    main()
