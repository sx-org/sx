// Zig HTTP server — equivalent to 32-http-server.sx
// Single-threaded, blocking, static response. Raw C sockets.

const std = @import("std");
const c = @cImport({
    @cInclude("sys/socket.h");
    @cInclude("netinet/in.h");
    @cInclude("unistd.h");
});

const body = "<html><body><h1>Hello from zig!</h1></body></html>";
const response = "HTTP/1.1 200 OK\r\n" ++
    "Content-Type: text/html\r\n" ++
    "Connection: close\r\n" ++
    std.fmt.comptimePrint("Content-Length: {d}\r\n", .{body.len}) ++
    "\r\n" ++ body;

pub fn main() !void {
    const port: u16 = 8081;

    const fd = c.socket(c.AF_INET, c.SOCK_STREAM, 0);
    if (fd < 0) return error.SocketFailed;

    var opt: c_int = 1;
    _ = c.setsockopt(fd, c.SOL_SOCKET, c.SO_REUSEADDR, &opt, @sizeOf(c_int));

    var addr: c.struct_sockaddr_in = std.mem.zeroes(c.struct_sockaddr_in);
    addr.sin_len = @sizeOf(c.struct_sockaddr_in);
    addr.sin_family = c.AF_INET;
    addr.sin_port = std.mem.nativeToBig(u16, port);
    addr.sin_addr.s_addr = 0;

    if (c.bind(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_in)) < 0)
        return error.BindFailed;

    if (c.listen(fd, 10) < 0)
        return error.ListenFailed;

    std.debug.print("listening on http://localhost:{d}\n", .{port});

    var count: u64 = 0;
    while (true) {
        const client = c.accept(fd, null, null);
        if (client < 0) continue;

        var buf: [4096]u8 = undefined;
        _ = c.read(client, &buf, buf.len);
        _ = c.write(client, response.ptr, response.len);
        _ = c.close(client);

        count += 1;
        if (count % 10000 == 0) {
            std.debug.print("[http] served {d} requests\n", .{count});
        }
    }
}
