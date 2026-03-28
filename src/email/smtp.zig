const std = @import("std");

pub const SmtpConfig = struct {
    host: []const u8,
    port: u16,
    username: []const u8,
    password: []const u8,
    from_address: []const u8,
    from_name: []const u8,
    use_tls: bool,

    pub fn fromEnv(allocator: std.mem.Allocator, environ_map: *std.process.Environ.Map) !SmtpConfig {
        const host = environ_map.get("SMTP_HOST") orelse "mail.smtp2go.com";
        const port_str = environ_map.get("SMTP_PORT") orelse "2525";
        const username = environ_map.get("SMTP_USER") orelse return error.MissingSmtpUser;
        const password = environ_map.get("SMTP_PASSWORD") orelse return error.MissingSmtpPassword;
        const from_address = environ_map.get("SMTP_FROM") orelse return error.MissingSmtpFrom;
        const from_name = environ_map.get("SMTP_FROM_NAME") orelse "Zepplin Registry";
        const use_tls_str = environ_map.get("SMTP_USE_TLS") orelse "true";

        return SmtpConfig{
            .host = try allocator.dupe(u8, host),
            .port = std.fmt.parseInt(u16, port_str, 10) catch 2525,
            .username = try allocator.dupe(u8, username),
            .password = try allocator.dupe(u8, password),
            .from_address = try allocator.dupe(u8, from_address),
            .from_name = try allocator.dupe(u8, from_name),
            .use_tls = std.mem.eql(u8, use_tls_str, "true"),
        };
    }

    pub fn deinit(self: *SmtpConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.host);
        allocator.free(self.username);
        allocator.free(self.password);
        allocator.free(self.from_address);
        allocator.free(self.from_name);
    }
};

pub const EmailMessage = struct {
    to: []const u8,
    to_name: ?[]const u8,
    subject: []const u8,
    body_text: []const u8,
    body_html: ?[]const u8,
};

pub const SmtpClient = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    config: SmtpConfig,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: SmtpConfig) SmtpClient {
        return .{
            .allocator = allocator,
            .io = io,
            .config = config,
        };
    }

    pub fn deinit(self: *SmtpClient) void {
        var config = self.config;
        config.deinit(self.allocator);
    }

    pub fn sendEmail(self: *SmtpClient, message: EmailMessage) !void {
        // Connect to SMTP server
        const address = try std.net.Address.resolveIp(self.config.host, self.config.port);
        var stream = try std.net.tcpConnectToAddress(self.io, address);
        defer stream.close(self.io);

        var read_buf: [1024]u8 = undefined;
        var write_buf: [4096]u8 = undefined;

        // Read greeting
        _ = try stream.reader(self.io, &read_buf).interface.readUntilDelimiter('\n');

        // EHLO
        try self.sendCommand(&stream, &write_buf, &read_buf, "EHLO zepplin.dev\r\n");

        // AUTH LOGIN
        try self.sendCommand(&stream, &write_buf, &read_buf, "AUTH LOGIN\r\n");

        // Send username (base64)
        var username_buf: [256]u8 = undefined;
        const username_encoded = std.base64.standard.Encoder.encode(&username_buf, self.config.username);
        const username_cmd = try std.fmt.bufPrint(&write_buf, "{s}\r\n", .{username_encoded});
        try self.sendCommand(&stream, &write_buf, &read_buf, username_cmd);

        // Send password (base64)
        var password_buf: [256]u8 = undefined;
        const password_encoded = std.base64.standard.Encoder.encode(&password_buf, self.config.password);
        const password_cmd = try std.fmt.bufPrint(&write_buf, "{s}\r\n", .{password_encoded});
        try self.sendCommand(&stream, &write_buf, &read_buf, password_cmd);

        // MAIL FROM
        const mail_from = try std.fmt.allocPrint(self.allocator, "MAIL FROM:<{s}>\r\n", .{self.config.from_address});
        defer self.allocator.free(mail_from);
        try self.sendCommand(&stream, &write_buf, &read_buf, mail_from);

        // RCPT TO
        const rcpt_to = try std.fmt.allocPrint(self.allocator, "RCPT TO:<{s}>\r\n", .{message.to});
        defer self.allocator.free(rcpt_to);
        try self.sendCommand(&stream, &write_buf, &read_buf, rcpt_to);

        // DATA
        try self.sendCommand(&stream, &write_buf, &read_buf, "DATA\r\n");

        // Build email content
        const email_content = try self.buildEmailContent(message);
        defer self.allocator.free(email_content);

        // Send email content
        var writer = stream.writer(self.io, &write_buf);
        try writer.interface.writeAll(email_content);
        try writer.interface.writeAll("\r\n.\r\n");
        try writer.interface.flush();

        // Read response
        _ = try stream.reader(self.io, &read_buf).interface.readUntilDelimiter('\n');

        // QUIT
        try self.sendCommand(&stream, &write_buf, &read_buf, "QUIT\r\n");
    }

    fn sendCommand(self: *SmtpClient, stream: *std.net.Stream, write_buf: *[4096]u8, read_buf: *[1024]u8, command: []const u8) !void {
        var writer = stream.writer(self.io, write_buf);
        try writer.interface.writeAll(command);
        try writer.interface.flush();
        _ = try stream.reader(self.io, read_buf).interface.readUntilDelimiter('\n');
    }

    fn buildEmailContent(self: *SmtpClient, message: EmailMessage) ![]u8 {
        const boundary = "----=_Part_0_1234567890";

        if (message.body_html) |html| {
            // Multipart email with HTML and text
            return std.fmt.allocPrint(self.allocator,
                \\From: {s} <{s}>
                \\To: {s}
                \\Subject: {s}
                \\MIME-Version: 1.0
                \\Content-Type: multipart/alternative; boundary="{s}"
                \\
                \\--{s}
                \\Content-Type: text/plain; charset=UTF-8
                \\
                \\{s}
                \\
                \\--{s}
                \\Content-Type: text/html; charset=UTF-8
                \\
                \\{s}
                \\
                \\--{s}--
            , .{
                self.config.from_name,
                self.config.from_address,
                message.to,
                message.subject,
                boundary,
                boundary,
                message.body_text,
                boundary,
                html,
                boundary,
            });
        } else {
            // Plain text email
            return std.fmt.allocPrint(self.allocator,
                \\From: {s} <{s}>
                \\To: {s}
                \\Subject: {s}
                \\Content-Type: text/plain; charset=UTF-8
                \\
                \\{s}
            , .{
                self.config.from_name,
                self.config.from_address,
                message.to,
                message.subject,
                message.body_text,
            });
        }
    }

    // Email templates
    pub fn sendVerificationEmail(self: *SmtpClient, to: []const u8, username: []const u8, token: []const u8, base_url: []const u8) !void {
        const verify_url = try std.fmt.allocPrint(self.allocator, "{s}/api/v1/auth/verify?token={s}", .{ base_url, token });
        defer self.allocator.free(verify_url);

        const body_text = try std.fmt.allocPrint(self.allocator,
            \\Hello {s},
            \\
            \\Welcome to Zepplin Registry! Please verify your email address by clicking the link below:
            \\
            \\{s}
            \\
            \\This link will expire in 24 hours.
            \\
            \\If you didn't create an account, you can safely ignore this email.
            \\
            \\Best regards,
            \\The Zepplin Team
        , .{ username, verify_url });
        defer self.allocator.free(body_text);

        const body_html = try std.fmt.allocPrint(self.allocator,
            \\<!DOCTYPE html>
            \\<html>
            \\<head><meta charset="UTF-8"></head>
            \\<body style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; background: #0f1419; color: #e6e1dc; padding: 2rem;">
            \\  <div style="max-width: 600px; margin: 0 auto; background: #1e2328; border-radius: 8px; padding: 2rem;">
            \\    <h1 style="color: #f7931e;">Welcome to Zepplin!</h1>
            \\    <p>Hello {s},</p>
            \\    <p>Please verify your email address by clicking the button below:</p>
            \\    <p style="text-align: center; margin: 2rem 0;">
            \\      <a href="{s}" style="display: inline-block; background: #36c692; color: #0f1419; padding: 1rem 2rem; border-radius: 4px; text-decoration: none; font-weight: bold;">Verify Email</a>
            \\    </p>
            \\    <p style="color: #666; font-size: 0.9rem;">This link will expire in 24 hours.</p>
            \\    <p style="color: #666; font-size: 0.9rem;">If you didn't create an account, you can safely ignore this email.</p>
            \\  </div>
            \\</body>
            \\</html>
        , .{ username, verify_url });
        defer self.allocator.free(body_html);

        try self.sendEmail(.{
            .to = to,
            .to_name = username,
            .subject = "Verify your Zepplin account",
            .body_text = body_text,
            .body_html = body_html,
        });
    }

    pub fn sendPasswordResetEmail(self: *SmtpClient, to: []const u8, username: []const u8, token: []const u8, base_url: []const u8) !void {
        const reset_url = try std.fmt.allocPrint(self.allocator, "{s}/reset-password?token={s}", .{ base_url, token });
        defer self.allocator.free(reset_url);

        const body_text = try std.fmt.allocPrint(self.allocator,
            \\Hello {s},
            \\
            \\We received a request to reset your password. Click the link below to set a new password:
            \\
            \\{s}
            \\
            \\This link will expire in 1 hour.
            \\
            \\If you didn't request a password reset, you can safely ignore this email.
            \\
            \\Best regards,
            \\The Zepplin Team
        , .{ username, reset_url });
        defer self.allocator.free(body_text);

        const body_html = try std.fmt.allocPrint(self.allocator,
            \\<!DOCTYPE html>
            \\<html>
            \\<head><meta charset="UTF-8"></head>
            \\<body style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; background: #0f1419; color: #e6e1dc; padding: 2rem;">
            \\  <div style="max-width: 600px; margin: 0 auto; background: #1e2328; border-radius: 8px; padding: 2rem;">
            \\    <h1 style="color: #f7931e;">Password Reset</h1>
            \\    <p>Hello {s},</p>
            \\    <p>We received a request to reset your password. Click the button below to set a new password:</p>
            \\    <p style="text-align: center; margin: 2rem 0;">
            \\      <a href="{s}" style="display: inline-block; background: #36c692; color: #0f1419; padding: 1rem 2rem; border-radius: 4px; text-decoration: none; font-weight: bold;">Reset Password</a>
            \\    </p>
            \\    <p style="color: #666; font-size: 0.9rem;">This link will expire in 1 hour.</p>
            \\    <p style="color: #666; font-size: 0.9rem;">If you didn't request a password reset, you can safely ignore this email.</p>
            \\  </div>
            \\</body>
            \\</html>
        , .{ username, reset_url });
        defer self.allocator.free(body_html);

        try self.sendEmail(.{
            .to = to,
            .to_name = username,
            .subject = "Reset your Zepplin password",
            .body_text = body_text,
            .body_html = body_html,
        });
    }

    pub fn sendPackagePublishedEmail(self: *SmtpClient, to: []const u8, username: []const u8, package_name: []const u8, version: []const u8, base_url: []const u8) !void {
        const package_url = try std.fmt.allocPrint(self.allocator, "{s}/packages/{s}", .{ base_url, package_name });
        defer self.allocator.free(package_url);

        const body_text = try std.fmt.allocPrint(self.allocator,
            \\Hello {s},
            \\
            \\Your package {s}@{s} has been published successfully!
            \\
            \\View it at: {s}
            \\
            \\Best regards,
            \\The Zepplin Team
        , .{ username, package_name, version, package_url });
        defer self.allocator.free(body_text);

        try self.sendEmail(.{
            .to = to,
            .to_name = username,
            .subject = try std.fmt.allocPrint(self.allocator, "Package {s}@{s} published", .{ package_name, version }),
            .body_text = body_text,
            .body_html = null,
        });
    }
};
