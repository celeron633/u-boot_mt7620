/* Host-side application test with mocked TCP events and SPI reads.
 * Run from the repository root:
 * cc -std=c99 -O2 -idirafter include tools/test_http_backup.c -o /tmp/test_http_backup
 * /tmp/test_http_backup
 */
#include <assert.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Bypass target-only common/uIP headers, retaining the real app state. */
#define __UIP_H__
typedef unsigned long ulong;
#undef BYTE_ORDER
#include "../httpd/uipopt.h"
#define DECLARE_GLOBAL_DATA_PTR
#define HTONS(x) (x)
#define WEBFAILSAFE_UPGRADE_TYPE_UBOOT 0
#define WEBFAILSAFE_UPGRADE_TYPE_FIRMWARE 1
#define WEBFAILSAFE_UPGRADE_TYPE_ART 2
#define WEBFAILSAFE_UPLOAD_UBOOT_SIZE_IN_BYTES 196608
#define WEBFAILSAFE_UPLOAD_ART_SIZE_IN_BYTES 65536
#define WEBFAILSAFE_UPLOAD_RAM_ADDRESS 0x80000000U
#define CFG_KERN_SIZE 0xf70000U

enum { CONNECT = 1, DATA = 2, ACK = 4, RETRANSMIT = 8,
       CLOSED = 16, ABORTED = 32, TIMEOUT = 64, POLL = 128 };
static unsigned int event, sent_len, read_count, writes;
static int closed, aborted, fail_read;
static unsigned char packet[1502], sent[1500];
static struct httpd_state states[2];
static struct test_conn {
    unsigned short lport, len, mss;
    void *appstate;
} connections[2], *uip_conn;
static unsigned char *uip_appdata = packet;
static unsigned int uip_len;
static struct test_board { unsigned int bi_flashsize; } board;
static struct { struct test_board *bd; } global_data;
#define gd (&global_data)
#define uip_connected() (event & CONNECT)
#define uip_newdata() (event & DATA)
#define uip_acked() (event & ACK)
#define uip_rexmit() (event & RETRANSMIT)
#define uip_closed() (event & CLOSED)
#define uip_aborted() (event & ABORTED)
#define uip_timedout() (event & TIMEOUT)
#define uip_poll() (event & POLL)
#define uip_mss() (uip_conn->mss)
#define uip_close() (closed = 1)
#define uip_abort() (aborted = 1)
#define uip_listen(port) ((void)(port))
static void send_packet(const void *data, unsigned int len) {
    assert(len && len <= UIP_TCP_MSS);
    memcpy(sent, data, len);
    sent_len = len;
}
#define uip_send(data, len) send_packet((data), (len))
static int env_reset_to_default(void) { writes++; return 0; }
static int saveenv(void) { writes++; return 0; }

/* The application has its own static atoi; keep libc's declaration intact. */
#define atoi httpd_atoi
#include "../httpd/httpd.c"
#undef atoi

int webfailsafe_ready_for_upgrade, webfailsafe_upgrade_type;
unsigned long NetBootFileXferSize;
unsigned char *webfailsafe_data_pointer;
void fs_init(void) {}
int fs_open(const char *name, struct fs_file *file) {
    (void)name;
    file->data = "HTTP/1.0 200 OK\r\n\r\nindex";
    file->len = strlen(file->data);
    return 1;
}
static unsigned char flash_byte(unsigned int offset) {
    return (offset ^ (offset >> 8) ^ (offset >> 16) ^ (offset >> 24) ^ 0xa5) & 255;
}
int raspi_read(char *buf, unsigned int from, int len) {
    int i;
    assert(len > 0 && len <= UIP_TCP_MSS);
    assert(from <= board.bi_flashsize && (unsigned int)len <= board.bi_flashsize - from);
    read_count++;
    if(fail_read) return len - 1;
    for(i = 0; i < len; i++) buf[i] = flash_byte(from + i);
    return len;
}

static void deliver(unsigned int flags, const char *request) {
    event = flags;
    sent_len = 0;
    memset(packet, 0xcc, sizeof(packet));
    uip_len = request ? strlen(request) : 0;
    if(request) memcpy(packet, request, uip_len);
    httpd_appcall();
    if(sent_len) uip_conn->len = sent_len;
}
static void start(unsigned int size, unsigned int mss) {
    memset(states, 0, sizeof(states));
    memset(connections, 0, sizeof(connections));
    global_data.bd = &board;
    board.bi_flashsize = size;
    closed = aborted = fail_read = 0;
    read_count = 0;
    uip_conn = &connections[0];
    uip_conn->lport = 80;
    uip_conn->mss = mss;
    uip_conn->appstate = &states[0];
    deliver(CONNECT, NULL);
    deliver(DATA, "GET /backup.bin HTTP/1.1\r\nHost: router\r\n\r\n");
}
static void check_retransmit(void) {
    unsigned char previous[1500];
    unsigned int len = sent_len, window = uip_conn->mss;
    memcpy(previous, sent, len);
    uip_conn->mss = 7; /* Window changes must not shorten outstanding data. */
    deliver(RETRANSMIT, NULL);
    assert(sent_len == len && !memcmp(previous, sent, len));
    uip_conn->mss = window;
}
static void check_header(unsigned int size) {
    char header[256], expected[64];
    unsigned int used = 0;
    while(hs->state == STATE_BACKUP_HEADER) {
        assert(used + sent_len < sizeof(header));
        memcpy(header + used, sent, sent_len);
        used += sent_len;
        check_retransmit();
        deliver(ACK, NULL);
    }
    header[used] = 0;
    sprintf(expected, "Content-Length: %u\r\n", size);
    assert(strstr(header, "HTTP/1.0 200 OK\r\n") == header);
    assert(strstr(header, "Content-Type: application/octet-stream\r\n"));
    assert(strstr(header, "filename=flash-backup.bin\r\n"));
    assert(strstr(header, expected));
    assert(strstr(header, "\r\n\r\n") == header + used - 4);
}
static void full_download(unsigned int size, unsigned int mss) {
    unsigned int offset = 0, segments = 0, i;
    start(size, mss);
    check_header(size);
    while(!closed) {
        assert(!aborted && sent_len && offset + sent_len <= size);
        for(i = 0; i < sent_len; i++) assert(sent[i] == flash_byte(offset + i));
        offset += sent_len;
        if(!(segments++ % 97)) check_retransmit();
        uip_conn->mss = segments % 13 ? mss : 37;
        deliver(ACK, NULL);
    }
    assert(offset == size && hs->state == STATE_NONE && !sent_len);
    assert(read_count && !writes && !webfailsafe_ready_for_upgrade);
    printf("PASS: %u MiB, MSS %u, %u segments\n", size >> 20, mss, segments);
}
int main(void) {
    unsigned int i;
    full_download(8U << 20, 1446);
    full_download(16U << 20, 511);
    full_download(32U << 20, 1446);
    full_download(8193, 31); /* Multi-segment header and short final body. */
    full_download(1446, 1446); /* Final body fills the segment exactly. */

    start(32U << 20, 1446);
    check_header(32U << 20);
    /* A second connection must not disturb the first connection's offset. */
    uip_conn = &connections[1];
    uip_conn->lport = 80;
    uip_conn->mss = 61;
    uip_conn->appstate = &states[1];
    deliver(CONNECT, NULL);
    deliver(DATA, "GET /backup.bin HTTP/1.0\r\n\r\n");
    check_header(32U << 20);
    deliver(ACK, NULL);
    uip_conn = &connections[0];
    deliver(ACK, NULL);
    for(i = 0; i < sent_len; i++) assert(sent[i] == flash_byte(1446 + i));
    check_retransmit();

    fail_read = 1;
    deliver(ACK, NULL);
    assert(aborted && !sent_len && hs->state == STATE_NONE);
    start(8U << 20, 1446); /* A new download works after a read error. */
    check_header(8U << 20);
    deliver(TIMEOUT, NULL);
    assert(aborted && hs->state == STATE_NONE);
    start(8U << 20, 1446);
    deliver(CLOSED, NULL);
    assert(closed && hs->state == STATE_NONE);
    start(8U << 20, 1446);
    deliver(ABORTED, NULL);
    assert(aborted && hs->state == STATE_NONE);
    start(0, 1446);
    assert(aborted && !sent_len);
    start(UINT_MAX, 1446);
    assert(aborted && !sent_len);
    start(8U << 20, 1446);
    deliver(CLOSED, NULL);
    closed = aborted = 0;
    deliver(DATA, "GET / HTTP/1.0\r\n\r\n");
    assert(sent_len && !aborted && !read_count); /* Existing page path. */
    deliver(CLOSED, NULL);
    aborted = 0;
    deliver(DATA, "GET /back");
    assert(aborted && !sent_len);
    assert(!writes && !webfailsafe_ready_for_upgrade);
    puts("PASS: concurrent downloads, read errors, disconnects, invalid size, existing page");
    return 0;
}
