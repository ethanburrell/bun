const bun = @import("bun");

const strings = bun.strings;
const JSC = @import("bun").JSC;
const js = JSC.C;
const ZigString = JSC.ZigString;

const fs = @import("../../fs.zig");
const default_allocator = bun.default_allocator;
const std = @import("std");
const testing = std.testing;

const ArrayIdentityContext = @import("../../identity_context.zig").ArrayIdentityContext;

const SNAPSHOTS_DIR = "__snapshots__/";
const EXTENSION = "snap";

pub fn resolveSnapshotPath(test_path: fs.Path, allocator: std.mem.Allocator) fs.Path {
    const dir_path = test_path.sourceDir();
    const file_name = test_path.name.base;
    // A test's name could be `feature.test.ts` and the base is `feature.test`
    // `test` should be stripped if it exists. This is the default patter of the
    // test runner.
    const file_name_stripped = std.mem.trimRight(u8, file_name, "test");
    var string_list = &[_][]const u8{ dir_path, SNAPSHOTS_DIR, file_name_stripped, EXTENSION };
    // maybe use resolve_path.joinAbsString
    const snapshot_file_path = strings.join(string_list, "", allocator) catch unreachable;

    return fs.Path.init(snapshot_file_path);
}

const IdentityContext = struct {
    pub fn eql(_: @This(), a: u64, b: u64) bool {
        return a == b;
    }

    pub fn hash(_: @This(), a: u64) u64 {
        return a;
    }
};

pub const SnapshotFile = struct {
    path: fs.Path,
    globalObject: ?*JSC.JSGlobalObject,
    // file_system: *fs.FileSystem,
    allocator: std.mem.Allocator,
    // This is the data that is read from the snapshot file
    // data is represented like:
    // { 'test constructor works': 4 }
    snapshotData: SnapshotError!JSC.JSValue,
    // This is the actual values that the user calls
    // used to update the snapshot file
    // snapshotArray: JSC.JSValue =
    tests: std.ArrayListUnmanaged(TestData) = .{},
    // : std.ArrayListUnmanaged(TestScope) = .{},
    counters: CountersMap,
    updateSnapshot: bool = true,

    pub const TestData = struct {
        k: ZigString,
        v: JSC.JSValue,
        count: u32,

        pub const List = std.ArrayListUnmanaged(TestData);

        fn lessThan(_: void, a: TestData, b: TestData) bool {
            return ZigString.cmpDesc(void{}, a.k, b.k);
            // std.mem[]
        }
    };

    pub const SnapshotError = error{SnapshotNotFound};

    pub const CountersMap = std.HashMap(u64, u32, IdentityContext, 80);

    // pub fn init(globalObject: *JSC.JSGlobalObject, path: fs.Path) !SnapshotFile {
    //     var _file_system = try fs.FileSystem.init1(globalObject.bunVM().allocator, null);
    //     var snapshot = SnapshotFile{ .globalObject = globalObject, .path = path, .file_system = _file_system, .allocator = globalObject.bunVM().allocator, .snapshotData = null };
    //     snapshot.readAndParseSnapshot(globalObject) catch unreachable;
    //     return snapshot;
    // }

    pub fn readAndParseSnapshot(this: *SnapshotFile, globalObject: *JSC.JSGlobalObject) void {
        var snapshot_contents = this.readSnapshot() catch return;
        const contents_string = ZigString.init(snapshot_contents);
        this.parseSnapshot(&contents_string, globalObject) catch unreachable;
    }

    pub fn readSnapshot(this: *SnapshotFile) !bun.string {
        // @TODO add check to throw error if the snapshot file does not exist.
        var file: std.fs.File = std.fs.cwd().openFile(this.path.text, .{ .mode = .read_write }) catch {
            this.snapshotData = SnapshotError.SnapshotNotFound;
            return SnapshotError.SnapshotNotFound;
        };
        const file_size = try file.getEndPos();
        var snapshot_contents = try this.allocator.alloc(u8, file_size);
        _ = try file.read(snapshot_contents);
        file.close();
        return snapshot_contents;
    }

    pub fn setSnapshotContents(this: *SnapshotFile, snapshot: js.JSValueRef) void {
        this.snapshotData = snapshot;
    }

    // Parses an existing by passing the snapshot file's contents into the javascript equivalent code:
    //      f = new Function("exports", snapshotContents);
    //      const param = {};
    //      f(param);
    // if the test snapshot file looks like: exports[`test name 1`] = `5`
    // the value of param will be set to: { test name 1: '5' }
    pub fn parseSnapshot(this: *SnapshotFile, snapshotContents: *const ZigString, globalObject: *JSC.JSGlobalObject) !void {
        // Arguments to create function
        var function_name = JSC.C.JSStringCreateStatic("anonymous", "anonymous".len);
        var param_name = JSC.C.JSStringCreateStatic("exports", "exports".len);
        var functionBody = JSC.C.JSStringCreateStatic(snapshotContents.ptr, snapshotContents.len);
        var func_url = JSC.C.JSStringCreateStatic("file:///snapshot.zig", "file:///snapshot.zig".len);
        // var exception_ptr = [_]JSC.C.JSValueRef{null};
        var exception_ptr: ?[*]JSC.JSValueRef = null;

        const function: js.JSObjectRef = JSC.C.JSObjectMakeFunction(globalObject, function_name, 1, &[_]JSC.C.JSStringRef{param_name}, functionBody, func_url, 1, exception_ptr);

        var expect_arg: js.JSValueRef = JSC.JSValue.createEmptyObject(globalObject, 0).asRef();
        const arguments = [1]js.JSValueRef{expect_arg};
        std.debug.print("JSObjectCallAsFunction\n", .{});
        // Call the function
        _ = JSC.C.JSObjectCallAsFunction(globalObject, function, null, 1, &arguments, exception_ptr) orelse unreachable;
        // Save the value of the parameter since it has the parsed snapshot value
        // @TODO need to do error checking here to see if the file / function failed
        // if (exception_ptr[0] != null) {
        //     std.debug.print("exception_ptr\n", .{});
        // }
        var z = ZigString.init("");
        JSC.JSValue.fromRef(expect_arg).toZigString(&z, globalObject);
        std.debug.print("parseSnapshot\n{s}\n", .{z});
        this.snapshotData = JSC.JSValue.fromRef(expect_arg);
    }

    fn incrementCounter(this: *SnapshotFile, testName: bun.string) !u32 {
        var count: u32 = 0;
        const hash = std.hash.Wyhash.hash(0, testName);
        if (this.counters.get(hash)) |val| {
            count = val;
        }
        count += 1;
        try this.counters.put(hash, count);
        return count;
    }

    // @TODO add support for hints later
    pub fn getSnapshotValue(this: *SnapshotFile, snapshotName: bun.string, globalObject: *JSC.JSGlobalObject) !JSC.JSValue {
        var count = try this.incrementCounter(snapshotName);
        const snapshot_key = std.fmt.allocPrint(this.allocator, "{s} {}", .{ snapshotName, count }) catch unreachable;

        const test_name_string = ZigString.init(snapshot_key);
        // @TODO get this to not segfault if the snapshot for the key doesn't exist
        const snapshotData = this.snapshotData catch {
            this.updateSnapshot = true;
            return SnapshotError.SnapshotNotFound;
            // this.globalObject.throw("The corresponding snapshot file did not exist: {s}", .{this.path.text});
            // return .zero;
        };
        const value = snapshotData.getIfPropertyExistsImpl(globalObject, test_name_string.ptr, @truncate(u32, test_name_string.len));
        if (value.isEmptyOrUndefinedOrNull()) {
            globalObject.throw("The snapshot `{s}` was not found in {s}", .{ snapshot_key, this.path.text });
            return .zero;
        }
        return value;
    }

    pub fn exists(this: *SnapshotFile) bool {
        return (fs.FileSystem.FilenameStore.instance.exists(this.path.text) or
            fs.FileSystem.DirnameStore.instance.exists(this.path.text)) and
            (fs.FileSystem.FilenameStore.instance.exists(this.path.pretty) or
            fs.FileSystem.DirnameStore.instance.exists(this.path.pretty));
    }

    // @TODO if the snapshot file is not found, then we set update = true
    // and save the contents of the test after the run
    pub fn match(this: *SnapshotFile, snapshotName: bun.string, actual: JSC.JSValue, not: bool, globalObject: *JSC.JSGlobalObject) !bool {
        this.globalObject = globalObject;
        const hash = std.hash.Wyhash.hash(0, snapshotName);
        const count: u32 = if (this.counters.get(hash)) |val| val else 0;
        try this.tests.append(this.allocator, TestData{ .k = ZigString.init(snapshotName), .v = actual, .count = count });

        const expected = this.getSnapshotValue(snapshotName, globalObject) catch |err| {
            if (err == SnapshotError.SnapshotNotFound) {
                std.debug.print("SnapshotNotFound\n", .{});
                // If the snapshot file does not exist, then we return true
                // and update the snapshot file
                return true;
            }
            globalObject.throw("The snapshot `{s}` was not found in {s}", .{ snapshotName, this.path.text });
            return false;
        };

        var pass = actual.deepEquals(expected, globalObject);

        if (not) pass = !pass;
        if (pass) return true;

        var fmt = JSC.ZigConsoleClient.Formatter{ .globalThis = globalObject };
        if (not) {
            globalObject.throw("Expected values to not be equal:\n\tExpected: {any}\n\tReceived: {any}", .{ expected.toFmt(globalObject, &fmt), actual.toFmt(globalObject, &fmt) });
        } else {
            globalObject.throw("Expected values to be equal:\n\tExpected: {any}\n\tReceived: {any}", .{ expected.toFmt(globalObject, &fmt), actual.toFmt(globalObject, &fmt) });
        }
        return false;
    }

    // pub fn escapeQuotesJSC(this: *SnapshotFile, actual: JSC.JSValue) !std.ArrayList(u8) {
    // var actual_stringified = JSC.ZigString.init("");
    // actual.toZigString(&actual_stringified, this.globalObject);
    // return try this.escapeQuotes(actual_stringified);
    // }

    // pub fn escapeQuotes(this: *SnapshotFile, actual: ZigString) !std.ArrayList(u8) {
    //     // @TODO what we need to do here is to look for any back tick and escape it
    //     // with a \` then we will be good to print to the code

    //     // Whenever possible, this iterator will return slices into `str` instead of
    //     // allocating. Sometimes this is not possible, for example, escaped characters
    //     // have be be unescape, so we need to allocate in this case.

    //     const actual_array: []u8 = try actual.toOwnedSlice(this.allocator);
    //     // var actual_stringified = actual.toSlice(this.globalObject, this.allocator);
    //     var list = std.ArrayList(u8).init(this.allocator);
    //     var start: usize = 0;

    //     for (actual_array) |c, i| {
    //         switch (c) {
    //             '`' => {
    //                 try list.appendSlice(actual_array[start..i]);
    //                 try list.appendSlice("\\`");
    //                 start = i + 1;
    //             },
    //             else => {},
    //         }
    //     }
    //     if (start < actual_array.len) {
    //         try list.appendSlice(actual_array[start..actual_array.len]);
    //     }
    //     std.debug.print("escapeQuotes {s}\n", .{actual_array});
    //     return list;
    // }

    // var less_than_func = fn (_: void, a_index: usize, b_index: usize) bool;
    // pub fn lessThanCallback(this: *SnapshotFile) less_than_func {
    //     return;
    // }

    pub fn openAndClearFile(this: *SnapshotFile) !std.fs.File {
        // const file = try std.fs.cwd().openFile(this.path.pretty, .{ .mode = .write_only });
        // file.close();
        // return try std.fs.cwd().openFile(this.path.pretty, .{ .mode = .write_only });
        try std.fs.cwd().deleteFile(this.path.pretty);
        return try std.fs.cwd().openFile(this.path.pretty, .{ .mode = .write_only });
    }

    // This function clears an existing snapshot file or opens a new one
    pub fn fetchFile(this: *SnapshotFile) !std.fs.File {
        std.debug.print("fetchFile {s}\n", .{this.path.name.dir});
        return this.openAndClearFile() catch |err| {
            // If the file has a problem opening, we create a new one
            std.debug.print("{s}", .{@errorName(err)});
            try std.fs.cwd().makePath(this.path.name.dir);
            std.debug.print("makePath {s}\n", .{this.path.pretty});
            return try std.fs.cwd().createFile(this.path.pretty, .{ .truncate = true });
            // .mode = .read_write, .lock = .Shared
        };
    }

    pub fn appendToFile(this: *SnapshotFile) void {
        std.debug.print("snapshot appendToFile\n", .{});
        // args.zig next L100 to find do string escaping
        const snapshot_file = this.fetchFile() catch std.debug.panic("Failed to create snapshot file", .{});
        defer snapshot_file.close();
        // defer snapshot_file.close();
        // @TODO create a new map that saves key -> recieved (JSValue).
        // Sort and iterate through it here. Then write each entry to the snapshot file
        // https://github.com/facebook/jest/blob/499fdf07745457200b8f6735d40adc02ad874e6a/packages/jest-snapshot/src/utils.ts#L203
        std.debug.print("appendToFile {}\n", .{this.tests.items.len});
        std.sort.sort(TestData, this.tests.items, void{}, TestData.lessThan);

        //  ZigString.cmpDesc(void{}, this.tests.items[a_index].k, this.tests.items[b_index].k)
        // this.tests.sort(.{ .lessThan = less_than_func });

        var i: usize = 0;
        while (i < this.tests.items.len) {
            const test_data = this.tests.items[i];
            // const value = escapeQuotesJSC(test_data.v);
            const key: ZigString = test_data.k;
            var value_stringified = JSC.ZigString.init("");
            test_data.v.toZigString(&value_stringified, this.globalObject orelse unreachable);
            const count = test_data.count;
            snapshot_file.writer().print("exports[`{s} {}`] = `{s}`;\n", .{ key, count, value_stringified }) catch unreachable;
            std.debug.print("data {s}\n", .{key});
            i += 1;
        }
        // for (this.tests.items) |test_data| {
        //     std.debug.print("appendToFile {s}", .{test_data.k});
        // }
        // JSC.ZigString.sortAsc(names[0..i]);
        // return JSC.JSValue.createStringArray(global, names.ptr, names.len, true);

        // var a = [_]ZigString{JSC.ZigString.init("`hi there 1`")};
        // this.escapeQuotes(JSC.JSValue.createStringArray(this.globalObject, &a, 1, true)) catch @panic("was not able to construct the snapshot");
    }
};

test "resolveSnapshotPath test" {
    const test_path = fs.Path.init("project/test/feature.test.ts");
    const snapshot_path = resolveSnapshotPath(test_path);
    try testing.expectEqualSlices(u8, snapshot_path.text, "project/test/__snapshots__/feature.snap");
}
