const std = @import("std");

pub const Transport = struct {
    in: *std.Io.Reader,
    out_file: std.Io.File,
    io: std.Io,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, in: *std.Io.Reader, out_file: std.Io.File) Transport {
        return .{
            .in = in,
            .out_file = out_file,
            .io = io,
            .allocator = allocator,
        };
    }

    /// Read one LSP message: parse Content-Length header, read body.
    pub fn readMessage(self: *Transport) ![]const u8 {
        var content_length: ?usize = null;

        // Parse headers (terminated by \r\n\r\n)
        while (true) {
            const line = try self.readLine();
            if (line.len == 0) break; // empty line = end of headers

            if (std.mem.startsWith(u8, line, "Content-Length: ")) {
                content_length = std.fmt.parseInt(usize, line["Content-Length: ".len..], 10) catch
                    return error.InvalidContentLength;
            }
        }

        const len = content_length orelse return error.MissingContentLength;

        const body = try self.allocator.alloc(u8, len);
        try self.in.readSliceAll(body);

        return body;
    }

    /// Write one LSP message: Content-Length header + body.
    pub fn writeMessage(self: *Transport, body: []const u8) !void {
        var buf: [32]u8 = undefined;
        const len_str = std.fmt.bufPrint(&buf, "{d}", .{body.len}) catch unreachable;

        self.out_file.writeStreamingAll(self.io, "Content-Length: ") catch return error.WriteFailed;
        self.out_file.writeStreamingAll(self.io, len_str) catch return error.WriteFailed;
        self.out_file.writeStreamingAll(self.io, "\r\n\r\n") catch return error.WriteFailed;
        self.out_file.writeStreamingAll(self.io, body) catch return error.WriteFailed;
    }

    /// Read a single line terminated by \r\n. Returns content without \r\n.
    fn readLine(self: *Transport) ![]const u8 {
        var buf = std.ArrayList(u8).empty;
        while (true) {
            const byte = self.in.takeByte() catch |err| switch (err) {
                error.EndOfStream => {
                    if (buf.items.len == 0) return error.EndOfStream;
                    return buf.items;
                },
                else => return error.ReadFailed,
            };

            if (byte == '\n') {
                const line = buf.items;
                if (line.len > 0 and line[line.len - 1] == '\r') {
                    return line[0 .. line.len - 1];
                }
                return line;
            }

            try buf.append(self.allocator, byte);
        }
    }
};
