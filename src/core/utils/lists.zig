const std = @import("std");

const assert = std.debug.assert;

pub const LinkedNode = std.DoublyLinkedList.Node;

pub fn PriorityLinkedList(comptime compareFn: fn (a: *LinkedNode, b: *LinkedNode) std.math.Order) type {
    return struct {
        const Self = @This();

        pub const Node = LinkedNode;

        /// Node inside the linked list wrapping the actual data.
        first: ?*Node = null,
        last: ?*Node = null,
        len: usize = 0,

        /// Insert a new node after an existing one.
        ///
        /// Arguments:
        ///     node: Pointer to a node in the list.
        ///     new_node: Pointer to the new node to insert.
        pub fn insertAfter(list: *Self, node: *Node, new_node: *Node) void {
            new_node.prev = node;
            if (node.next) |next_node| {
                // Intermediate node.
                new_node.next = next_node;
                next_node.prev = new_node;
            } else {
                // Last element of the list.
                new_node.next = null;
                list.last = new_node;
            }
            node.next = new_node;

            list.len += 1;
        }

        /// Insert a new node before an existing one.
        ///
        /// Arguments:
        ///     node: Pointer to a node in the list.
        ///     new_node: Pointer to the new node to insert.
        pub fn insertBefore(list: *Self, node: *Node, new_node: *Node) void {
            new_node.next = node;
            if (node.prev) |prev_node| {
                // Intermediate node.
                new_node.prev = prev_node;
                prev_node.next = new_node;
            } else {
                // First element of the list.
                new_node.prev = null;
                list.first = new_node;
            }
            node.prev = new_node;

            list.len += 1;
        }

        pub fn add(list: *Self, node: *Node) void {
            var it: ?*Node = list.first;
            while (it) |n| {
                switch (compareFn(node, n)) {
                    .lt => list.insertBefore(n, node),
                    .eq => list.insertAfter(n, node),
                    .gt => {
                        if (n.next) |next_node| {
                            it = next_node;
                            continue;
                        }
                        list.insertAfter(n, node);
                    },
                }
                return;
            }
            list.first = node;
            list.last = node;
            list.len = 1;
        }

        pub fn addBack(list: *Self, node: *Node) void {
            var it: ?*Node = list.last;
            while (it) |n| {
                switch (compareFn(node, n)) {
                    .lt => {
                        if (n.prev) |prev_node| {
                            it = prev_node;
                            continue;
                        }
                        list.insertBefore(n, node);
                    },
                    .eq => list.insertAfter(n, node),
                    .gt => list.insertAfter(n, node),
                }
                return;
            }
            list.first = node;
            list.last = node;
            list.len = 1;
        }

        /// Remove a node from the list.
        ///
        /// Arguments:
        ///     node: Pointer to the node to be removed.
        pub fn remove(list: *Self, node: *Node) void {
            if (node.prev) |prev_node| {
                // Intermediate node.
                prev_node.next = node.next;
            } else {
                // First element of the list.
                list.first = node.next;
            }

            if (node.next) |next_node| {
                // Intermediate node.
                next_node.prev = node.prev;
            } else {
                // Last element of the list.
                list.last = node.prev;
            }

            list.len -= 1;
            assert(list.len == 0 or (list.first != null and list.last != null));
        }

        /// Remove and return the last node in the list.
        ///
        /// Returns:
        ///     A pointer to the last node in the list.
        pub fn pop(list: *Self) ?*Node {
            const last = list.last orelse return null;
            list.remove(last);
            return last;
        }

        /// Remove and return the first node in the list.
        ///
        /// Returns:
        ///     A pointer to the first node in the list.
        pub fn popFirst(list: *Self) ?*Node {
            const first = list.first orelse return null;
            list.remove(first);
            return first;
        }
    };
}

const ValuedNode = struct {
    node: LinkedNode = .{},
    value: u32,

    pub fn from(node: *LinkedNode) *@This() {
        return @fieldParentPtr("node", node);
    }
};

fn lessThan(a: *LinkedNode, b: *LinkedNode) std.math.Order {
    return std.math.order(ValuedNode.from(a).value, ValuedNode.from(b).value);
}

fn greaterThan(a: *LinkedNode, b: *LinkedNode) std.math.Order {
    return lessThan(a, b).invert();
}

const PLlt = PriorityLinkedList(lessThan);
const PLgt = PriorityLinkedList(greaterThan);

test "PriorityLinkedList: add and pop min" {
    var list: PLlt = .{};

    var node1: ValuedNode = .{ .value = 7 };
    var node2: ValuedNode = .{ .value = 12 };
    var node3: ValuedNode = .{ .value = 13 };
    var node4: ValuedNode = .{ .value = 23 };
    var node5: ValuedNode = .{ .value = 25 };
    var node6: ValuedNode = .{ .value = 54 };

    list.add(&node5.node);
    list.add(&node2.node);
    list.add(&node3.node);
    list.add(&node1.node);
    list.add(&node4.node);
    list.add(&node6.node);

    try std.testing.expectEqual(@as(u32, 7), ValuedNode.from(list.popFirst().?).value);
    try std.testing.expectEqual(@as(u32, 12), ValuedNode.from(list.popFirst().?).value);
    try std.testing.expectEqual(@as(u32, 13), ValuedNode.from(list.popFirst().?).value);
    try std.testing.expectEqual(@as(u32, 23), ValuedNode.from(list.popFirst().?).value);
    try std.testing.expectEqual(@as(u32, 25), ValuedNode.from(list.popFirst().?).value);
    try std.testing.expectEqual(@as(u32, 54), ValuedNode.from(list.popFirst().?).value);
    try std.testing.expect(list.popFirst() == null);
}

test "PriorityLinkedList: add and pop min same" {
    var list: PLlt = .{};

    var node1: ValuedNode = .{ .value = 1 };
    var node2: ValuedNode = .{ .value = 1 };
    var node3: ValuedNode = .{ .value = 2 };
    var node4: ValuedNode = .{ .value = 2 };
    var node5: ValuedNode = .{ .value = 1 };
    var node6: ValuedNode = .{ .value = 1 };

    list.add(&node5.node);
    list.add(&node2.node);
    list.add(&node3.node);
    list.add(&node1.node);
    list.add(&node4.node);
    list.add(&node6.node);

    try std.testing.expectEqual(@as(u32, 1), ValuedNode.from(list.popFirst().?).value);
    try std.testing.expectEqual(@as(u32, 1), ValuedNode.from(list.popFirst().?).value);
    try std.testing.expectEqual(@as(u32, 1), ValuedNode.from(list.popFirst().?).value);
    try std.testing.expectEqual(@as(u32, 1), ValuedNode.from(list.popFirst().?).value);
    try std.testing.expectEqual(@as(u32, 2), ValuedNode.from(list.popFirst().?).value);
    try std.testing.expectEqual(@as(u32, 2), ValuedNode.from(list.popFirst().?).value);
    try std.testing.expect(list.popFirst() == null);
}

test "PriorityLinkedList: add and pop max" {
    var list: PLgt = .{};

    var node1: ValuedNode = .{ .value = 7 };
    var node2: ValuedNode = .{ .value = 12 };
    var node3: ValuedNode = .{ .value = 13 };
    var node4: ValuedNode = .{ .value = 23 };
    var node5: ValuedNode = .{ .value = 25 };
    var node6: ValuedNode = .{ .value = 54 };

    list.add(&node5.node);
    list.add(&node2.node);
    list.add(&node3.node);
    list.add(&node1.node);
    list.add(&node4.node);
    list.add(&node6.node);

    try std.testing.expectEqual(@as(u32, 54), ValuedNode.from(list.popFirst().?).value);
    try std.testing.expectEqual(@as(u32, 25), ValuedNode.from(list.popFirst().?).value);
    try std.testing.expectEqual(@as(u32, 23), ValuedNode.from(list.popFirst().?).value);
    try std.testing.expectEqual(@as(u32, 13), ValuedNode.from(list.popFirst().?).value);
    try std.testing.expectEqual(@as(u32, 12), ValuedNode.from(list.popFirst().?).value);
    try std.testing.expectEqual(@as(u32, 7), ValuedNode.from(list.popFirst().?).value);
    try std.testing.expect(list.popFirst() == null);
}

test "PriorityLinkedList: add and pop max same" {
    var list: PLgt = .{};

    var node1: ValuedNode = .{ .value = 1 };
    var node2: ValuedNode = .{ .value = 1 };
    var node3: ValuedNode = .{ .value = 2 };
    var node4: ValuedNode = .{ .value = 2 };
    var node5: ValuedNode = .{ .value = 1 };
    var node6: ValuedNode = .{ .value = 1 };

    list.add(&node5.node);
    list.add(&node2.node);
    list.add(&node3.node);
    list.add(&node1.node);
    list.add(&node4.node);
    list.add(&node6.node);

    try std.testing.expectEqual(@as(u32, 2), ValuedNode.from(list.popFirst().?).value);
    try std.testing.expectEqual(@as(u32, 2), ValuedNode.from(list.popFirst().?).value);
    try std.testing.expectEqual(@as(u32, 1), ValuedNode.from(list.popFirst().?).value);
    try std.testing.expectEqual(@as(u32, 1), ValuedNode.from(list.popFirst().?).value);
    try std.testing.expectEqual(@as(u32, 1), ValuedNode.from(list.popFirst().?).value);
    try std.testing.expectEqual(@as(u32, 1), ValuedNode.from(list.popFirst().?).value);
    try std.testing.expect(list.popFirst() == null);
}
