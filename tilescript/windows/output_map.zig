const std = @import("std");
usingnamespace @import("imgui");
const upaya = @import("upaya");
const ts = @import("../tilescript.zig");
const colors = @import("../colors.zig");
const processor = @import("../rule_processor.zig");
const object_editor = @import("object_editor.zig");

var dragged_obj_index: ?usize = null;
var drag_type: enum { move, link } = .move;

pub fn drawWindow(state: *ts.AppState) void {
    // only process map data when it changes
    if (state.map_data_dirty) {
        processor.generateProcessedMap(state);
        processor.generateOutputMap(state);
        state.map_data_dirty = false;
    }

    if (igBegin("Output Map", null, ImGuiWindowFlags_NoCollapse | ImGuiWindowFlags_AlwaysHorizontalScrollbar)) {
        draw(state);
    }
    igEnd();
}

fn draw(state: *ts.AppState) void {
    const origin = ogGetCursorScreenPos();
    const map_size = state.mapSize();

    ogAddRectFilled(igGetWindowDrawList(), origin, map_size, colors.colorRgb(0, 0, 0));
    _ = ogInvisibleButton("##output-map-button", map_size, ImGuiButtonFlags_None);

    var y: usize = 0;
    while (y < state.map.h) : (y += 1) {
        var x: usize = 0;
        while (x < state.map.w) : (x += 1) {
            var tile = state.final_map_data[x + y * state.map.w];
            if (tile == 0) continue;

            if (state.prefs.show_animations) {
                if (state.map.tryGetAnimation(tile - 1)) |anim| {
                    if (anim.tiles.len > 0) {
                        const sec_per_frame = @intToFloat(f32, anim.rate) / 1000;
                        const iter_duration = sec_per_frame * @intToFloat(f32, anim.tiles.len);
                        const elapsed = @mod(@intToFloat(f32, @divTrunc(std.time.milliTimestamp(), 1000)), iter_duration);
                        const frame = upaya.math.ifloor(usize, elapsed / sec_per_frame);
                        tile = anim.tiles.items[frame] + 1;
                    } else {
                        continue;
                    }
                }
            }

            const offset_x = @intToFloat(f32, x) * state.map_rect_size;
            const offset_y = @intToFloat(f32, y) * state.map_rect_size;
            var tl = ImVec2{ .x = origin.x + offset_x, .y = origin.y + offset_y };
            drawTile(state, tl, tile - 1);
        }
    }

    // draw objects
    if (state.prefs.show_objects) {
        for (state.map.objects.items) |obj, i| {
            const tl = ImVec2{ .x = origin.x + @intToFloat(f32, obj.x) * state.map_rect_size, .y = origin.y + @intToFloat(f32, obj.y) * state.map_rect_size };
            const color = if (dragged_obj_index != null and dragged_obj_index.? == i) colors.object_selected else colors.object;
            ogAddQuad(igGetWindowDrawList(), tl, state.map_rect_size, color, 1);

            for (obj.props.items) |prop| {
                switch (prop.value) {
                    .link => |linked_id| {
                        const half_rect = @divTrunc(state.map_rect_size, 2);
                        const linked_obj = state.map.getObjectWithId(linked_id);

                        // offset the line from the center of our tile
                        var tl_offset = tl;
                        tl_offset.x += half_rect;
                        tl_offset.y += half_rect;

                        const other = ImVec2{ .x = origin.x + half_rect + @intToFloat(f32, linked_obj.x) * state.map_rect_size, .y = origin.y + half_rect + @intToFloat(f32, linked_obj.y) * state.map_rect_size };
                        ogImDrawList_AddLine(igGetWindowDrawList(), tl_offset, other, colors.object_link, 1);
                    },
                    else => {},
                }
            }
        }
    }

    if (igIsItemHovered(ImGuiHoveredFlags_None)) {
        handleInput(state, origin);
    } else {
        dragged_obj_index = null;
    }
}

/// returns the index of the object under the mouse or null
fn objectIndexUnderMouse(state: *ts.AppState, origin: ImVec2) ?usize {
    var tile = ts.tileIndexUnderMouse(@floatToInt(usize, state.map_rect_size), origin);
    for (state.map.objects.items) |obj, i| {
        if (obj.x == tile.x and obj.y == tile.y) {
            return i;
        }
    }
    return null;
}

fn handleInput(state: *ts.AppState, origin: ImVec2) void {
    // scrolling via drag with alt key down
    if (igIsMouseDragging(ImGuiMouseButton_Left, 0) and (igGetIO().KeyAlt or igGetIO().KeySuper)) {
        var scroll_delta = ogGetMouseDragDelta(0, 0);        

        igSetScrollXFloat(igGetScrollX() - scroll_delta.x);
        igSetScrollYFloat(igGetScrollY() - scroll_delta.y);
        igResetMouseDragDelta(ImGuiMouseButton_Left);
        return;
    }

    if (!state.object_edit_mode) {
        return;
    }

    if (igIsMouseClicked(ImGuiMouseButton_Left, false) or igIsMouseClicked(ImGuiMouseButton_Right, false)) {
        // figure out if we clicked on any of our objects
        var tile = ts.tileIndexUnderMouse(@floatToInt(usize, state.map_rect_size), origin);
        for (state.map.objects.items) |obj, i| {
            if (obj.x == tile.x and obj.y == tile.y) {
                dragged_obj_index = i;
                object_editor.setSelectedObject(i);
                @import("objects.zig").setSelectedObject(i);
                drag_type = if (igIsMouseClicked(ImGuiMouseButton_Left, false)) .move else .link;
                break;
            }
        }
    } else if (dragged_obj_index != null) {
        if (drag_type == .move) {
            if (igIsMouseDragging(ImGuiMouseButton_Left, 0)) {
                var tile = ts.tileIndexUnderMouse(@floatToInt(usize, state.map_rect_size), origin);
                var obj = &state.map.objects.items[dragged_obj_index.?];
                obj.x = tile.x;
                obj.y = tile.y;
            } else if (igIsMouseReleased(ImGuiMouseButton_Left)) {
                dragged_obj_index = null;
            }
        } else if (drag_type == .link) {
            if (igIsMouseDragging(ImGuiMouseButton_Right, 0)) {
                // highlight the drop target if we have one
                if (objectIndexUnderMouse(state, origin)) |index| {
                    if (index != dragged_obj_index.?) {
                        const obj = state.map.objects.items[index];
                        const tl = ImVec2{ .x = origin.x - 2 + @intToFloat(f32, obj.x) * state.map_rect_size, .y = origin.y - 2 + @intToFloat(f32, obj.y) * state.map_rect_size };
                        ogAddQuad(igGetWindowDrawList(), tl, state.map_rect_size + 4, igColorConvertFloat4ToU32(igGetStyle().Colors[ImGuiCol_DragDropTarget]), 2);
                    }
                }

                ogImDrawList_AddLine(igGetWindowDrawList(), igGetIO().MouseClickedPos[1], igGetIO().MousePos, colors.object_drag_link, 2);
            } else if (igIsMouseReleased(ImGuiMouseButton_Right)) {
                if (objectIndexUnderMouse(state, origin)) |index| {
                    if (index != dragged_obj_index.?) {
                        var obj = &state.map.objects.items[dragged_obj_index.?];
                        obj.addProp(.{ .link = state.map.objects.items[index].id });

                        var prop = &obj.props.items[obj.props.items.len - 1];
                        std.mem.copy(u8, &prop.name, "link");
                    }
                }
                dragged_obj_index = null;
            }
        }
    }
}

fn drawTile(state: *ts.AppState, tl: ImVec2, tile: usize) void {
    var br = tl;
    br.x += @intToFloat(f32, state.map.tile_size * state.prefs.tile_size_multiplier);
    br.y += @intToFloat(f32, state.map.tile_size * state.prefs.tile_size_multiplier);

    const rect = ts.uvsForTile(state, tile);
    const uv0 = ImVec2{ .x = rect.x, .y = rect.y };
    const uv1 = ImVec2{ .x = rect.x + rect.width, .y = rect.y + rect.height };

    ogImDrawList_AddImage(igGetWindowDrawList(), state.texture.imTextureID(), tl, br, uv0, uv1, 0xffffffff);
}
