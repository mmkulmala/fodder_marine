// Cannon Fodder–style mini‑prototype in Odin (single file)
// -------------------------------------------------------
// Features
// - Top‑down tile map
// - Click‑to‑move squad with simple A* pathfinding on a grid
// - Right‑click to fire; basic bullets and enemies
// - Very small ECS‑ish structs; simple fixed‑timestep loop
// - SDL2 rendering (rectangles + lines)
//
// Build prerequisites
// - Install Odin: https://odin-lang.org/
// - Install SDL2 dev libs (headers + runtime)
// - Ensure Odin's vendor collections are available (the official repo includes vendor:sdl2)
//
// Build & run (adjust the vendor path if needed):
// odin run main.odin -collection:vendor=../path/to/odin/vendor
//   or, if your ODIN_ROOT has vendor preconfigured, just:
// odin run main.odin

package main

import "core:fmt"
import m "core:math"
import time "core:time"
import sdl "vendor:sdl2"

// -------------------------------------------------------
// Config
// -------------------------------------------------------


SCREEN_W :: 1024
SCREEN_H :: 640
TILE_SIZE :: 32
GRID_W :: SCREEN_W / TILE_SIZE
GRID_H :: SCREEN_H / TILE_SIZE
PLAYER_SPEED :: 120.0 // px/s
BULLET_SPEED :: 340.0
ENEMY_SPEED :: 60.0
FIRE_COOLDOWN :: 0.18 // seconds between shots per unit
UNIT_RADIUS :: 8
ENEMY_RADIUS :: 10
BULLET_RADIUS :: 3
MAX_UNITS :: 4
MAX_ENEMIES :: 24
MAX_BULLETS :: 128
PATH_MAX :: 256
DT :: 1.0 / 120.0 // fixed dt

// UI
QUIT_BTN_X :: 10
QUIT_BTN_Y :: 10
QUIT_BTN_W :: 80
QUIT_BTN_H :: 28

// -------------------------------------------------------
// Basic Types
// -------------------------------------------------------

// Simple RNG (LCG)
Rng :: struct {
	state: u64,
}

rng_seed :: proc(r: ^Rng, seed: u64) {
	s := seed
	if s == 0 {s = 0x9E3779B97F4A7C15}
	r^.state = s
}

rng_next_u32 :: proc(r: ^Rng) -> u32 {
	// 64-bit LCG, return upper 32 bits
	r^.state = r^.state * 6364136223846793005 + 1
	return cast(u32)(r^.state >> 32)
}

rng_int_between :: proc(r: ^Rng, lo, hi: i32) -> i32 {
	if hi <= lo {return lo}
	span := cast(u32)(hi - lo + 1)
	n := rng_next_u32(r)
	return lo + cast(i32)(n % span)
}

rng_random_between :: proc(r: ^Rng, lo, hi: f32) -> f32 {
	t := cast(f32)(rng_next_u32(r)) / 4294967295.0
	return lo + (hi - lo) * t
}

Vector2 :: struct {
	x: f32,
	y: f32,
}

v2 :: proc(x: f32, y: f32) -> Vector2 {return Vector2{x, y}}
add :: proc(a: Vector2, b: Vector2) -> Vector2 {return v2(a.x + b.x, a.y + b.y)}
sub :: proc(a: Vector2, b: Vector2) -> Vector2 {return v2(a.x - b.x, a.y - b.y)}
scale :: proc(a: Vector2, s: f32) -> Vector2 {return v2(a.x * s, a.y * s)}
vlen :: proc(a: Vector2) -> f32 {return m.sqrt(a.x * a.x + a.y * a.y)}
norm :: proc(a: Vector2) -> Vector2 {L := vlen(a)
	if L > 0.00001 {return scale(a, 1.0 / L)}
	return v2(0, 0)}

// Grid helpers

grid_to_screen :: proc(gx, gy: i32) -> Vector2 {
	return v2(cast(f32)gx * TILE_SIZE + TILE_SIZE * 0.5, cast(f32)gy * TILE_SIZE + TILE_SIZE * 0.5)
}

screen_to_grid :: proc(p: Vector2) -> (gx: i32, gy: i32) {
	gx = clamp_i32(cast(i32)(p.x / TILE_SIZE), 0, GRID_W - 1)
	gy = clamp_i32(cast(i32)(p.y / TILE_SIZE), 0, GRID_H - 1)
	return
}

clamp_i32 :: proc(x, lo, hi: i32) -> i32 {
	if x < lo {return lo}
	if x > hi {return hi}
	return x
}

// -------------------------------------------------------
// World State
// -------------------------------------------------------

Tile :: enum u8 {
	Sand,
	Wood,
	Water,
}

GridPos :: struct {
	x: i32,
	y: i32,
}

World :: struct {
	tiles: [GRID_W * GRID_H]Tile,
}

get_tile :: proc(w: ^World, x, y: i32) -> ^Tile {
	if x < 0 || y < 0 || x >= GRID_W || y >= GRID_H {return nil}
	return &w.tiles[y * GRID_W + x]
}

is_blocked :: proc(w: ^World, x, y: i32) -> bool {
	t := get_tile(w, x, y)
	if t == nil {return true}
	// Wood and water are impassable; sand is walkable
	return t^ == .Wood || t^ == .Water
}

make_test_map :: proc(w: ^World) {
	// Fill with sand
	for y in 0 ..< GRID_H do for x in 0 ..< GRID_W {
		w.tiles[y * GRID_W + x] = .Sand
	}
	// Border as water
	for x in 0 ..< GRID_W {
		w.tiles[0 * GRID_W + x] = .Water
		w.tiles[(GRID_H - 1) * GRID_W + x] = .Water
	}
	for y in 0 ..< GRID_H {
		w.tiles[y * GRID_W + 0] = .Water
		w.tiles[y * GRID_W + (GRID_W - 1)] = .Water
	}
	// Wood obstacles (impassable) with bounds guards
	for x in 10 ..= 20 {
		if 8 < GRID_H && x < GRID_W {
			w.tiles[8 * GRID_W + x] = .Wood
		}
	}
	for y in 12 ..= 20 {
		if y < GRID_H && 24 < GRID_W {
			w.tiles[y * GRID_W + 24] = .Wood
		}
	}
	for x in 30 ..= 36 {
		if 16 < GRID_H && x < GRID_W {
			w.tiles[16 * GRID_W + x] = .Wood
		}
	}
	// Small water pond
	for y in 4 ..= 6 do for x in 4 ..= 8 {
		if y < GRID_H && x < GRID_W {
			w.tiles[y * GRID_W + x] = .Water
		}
	}
}

// -------------------------------------------------------
// Entities
// -------------------------------------------------------

Unit :: struct {
	pos:           Vector2,
	vel:           Vector2,
	target:        Vector2,
	fire_cooldown: f32,
	path:          [PATH_MAX]GridPos,
	path_len:      i32,
	path_idx:      i32,
	alive:         bool,
}

Enemy :: struct {
	pos:      Vector2,
	alive:    bool,
	targeted: bool,
}

Bullet :: struct {
	pos:         Vector2,
	vel:         Vector2,
	alive:       bool,
	from_player: bool,
}

Game :: struct {
	world:        World,
	units:        [MAX_UNITS]Unit,
	enemies:      [MAX_ENEMIES]Enemy,
	bullets:      [MAX_BULLETS]Bullet,
	rng:          Rng,
	selected_all: bool,
}

// -------------------------------------------------------
// Pathfinding (A* on grid)
// -------------------------------------------------------

Node :: struct {
	x, y:   i32,
	g, f:   f32,
	parent: i32,
	open:   bool,
	closed: bool,
}

// Simple binary heap for open set by f-score
heap_push :: proc(heap: ^[dynamic]i32, nodes: ^[]Node, idx: i32, heap_len: ^int) {
	i := heap_len^
	// ensure capacity
	if i >= len(heap^) {
		append(heap, idx)
	} else {
		heap^[i] = idx
	}
	heap_len^ = i + 1
	for i > 0 {
		p := (i - 1) / 2
		if nodes^[heap^[i]].f < nodes^[heap^[p]].f {
			tmp := heap^[i];heap^[i] = heap^[p];heap^[p] = tmp
			i = p
		} else {break}
	}
}

heap_pop :: proc(heap: ^[dynamic]i32, nodes: ^[]Node, heap_len: ^int) -> i32 {
	if heap_len^ == 0 {return -1}
	out := heap^[0]
	last := heap^[heap_len^ - 1]
	heap^[0] = last
	heap_len^ -= 1
	i := 0
	for true {
		l := 2 * i + 1
		r := 2 * i + 2
		smallest := i
		if l < heap_len^ && nodes^[heap^[l]].f < nodes^[heap^[smallest]].f do smallest = l
		if r < heap_len^ && nodes^[heap^[r]].f < nodes^[heap^[smallest]].f do smallest = r
		if smallest != i {
			tmp := heap^[i];heap^[i] = heap^[smallest];heap^[smallest] = tmp
			i = smallest
		} else {break}
	}
	return out
}

hash_xy :: proc(x, y: i32) -> i32 {return y * GRID_W + x}

reconstruct_path :: proc(nodes: []Node, end_idx: i32, out: ^[PATH_MAX]GridPos) -> i32 {
	n := end_idx
	count: i32 = 0
	for n >= 0 && count < PATH_MAX {
		out[count] = GridPos{nodes[n].x, nodes[n].y}
		count += 1
		n = nodes[n].parent
	}
	// reverse in-place
	for i in 0 ..< count / 2 {
		j := count - 1 - i
		tmp := out[i]
		out[i] = out[j]
		out[j] = tmp
	}
	return count
}

heuristic :: proc(ax, ay, bx, by: i32) -> f32 {
	// Manhattan
	dx := m.abs(cast(f32)(ax - bx))
	dy := m.abs(cast(f32)(ay - by))
	return dx + dy
}

find_path :: proc(g: ^Game, startx, starty, goalx, goaly: i32, out: ^[PATH_MAX]GridPos) -> i32 {
	if is_blocked(&g.world, goalx, goaly) {return 0}

	nodes := make([]Node, GRID_W * GRID_H)
	for i in 0 ..< len(nodes) {
		nodes[i].x = cast(i32)(i % GRID_W)
		nodes[i].y = cast(i32)(i / GRID_W)
		nodes[i].g = 1e9
		nodes[i].f = 1e9
		nodes[i].parent = -1
		nodes[i].open = false
		nodes[i].closed = false
	}

	start := hash_xy(startx, starty)
	goal := hash_xy(goalx, goaly)

	nodes[start].g = 0
	nodes[start].f = heuristic(startx, starty, goalx, goaly)

	open_heap: [dynamic]i32
	heap_len: int = 0
	heap_push(&open_heap, &nodes, start, &heap_len)
	nodes[start].open = true

	dirs := [8]GridPos{{1, 0}, {-1, 0}, {0, 1}, {0, -1}, {1, 1}, {-1, 1}, {1, -1}, {-1, -1}}

	for heap_len > 0 {
		current := heap_pop(&open_heap, &nodes, &heap_len)
		if current == goal do return reconstruct_path(nodes, current, out)
		nodes[current].closed = true

		cx := nodes[current].x
		cy := nodes[current].y

		for d in dirs {
			nx := cx + d.x
			ny := cy + d.y
			if nx < 0 || ny < 0 || nx >= GRID_W || ny >= GRID_H do continue
			if is_blocked(&g.world, nx, ny) do continue
			ni := hash_xy(nx, ny)
			if nodes[ni].closed do continue

			// Diagonal costs slightly higher
			step: f32
			if d.x != 0 && d.y != 0 {
				step = 1.4
			} else {
				step = 1.0
			}
			new_g := nodes[current].g + step
			if new_g < nodes[ni].g {
				nodes[ni].g = new_g
				nodes[ni].f = new_g + heuristic(nx, ny, goalx, goaly)
				nodes[ni].parent = current
				if !nodes[ni].open {
					heap_push(&open_heap, &nodes, ni, &heap_len)
					nodes[ni].open = true
				}
			}
		}
	}

	return 0 // no path
}

// -------------------------------------------------------
// Game init
// -------------------------------------------------------

spawn_enemies :: proc(g: ^Game) {
	count := 0
	for i in 0 ..< MAX_ENEMIES {
		// random open tile
		tries := 0
		for tries < 64 {
			gx := rng_int_between(&g.rng, 2, GRID_W - 3)
			gy := rng_int_between(&g.rng, 2, GRID_H - 3)
			if !is_blocked(&g.world, gx, gy) {
				g.enemies[i].pos = grid_to_screen(gx, gy)
				g.enemies[i].alive = true
				count += 1
				break
			}
			tries += 1
		}
	}
}

init_game :: proc() -> Game {
	g: Game
	make_test_map(&g.world)
	rng_seed(&g.rng, cast(u64)sdl.GetTicks())

	// Units spawn near bottom-left
	start_tiles := [MAX_UNITS]GridPos {
		{2, GRID_H - 3},
		{3, GRID_H - 3},
		{2, GRID_H - 4},
		{3, GRID_H - 4},
	}
	for i in 0 ..< MAX_UNITS {
		st := start_tiles[i]
		g.units[i].pos = grid_to_screen(st.x, st.y)
		g.units[i].target = g.units[i].pos
		g.units[i].alive = true
		g.units[i].path_len = 0
		g.units[i].path_idx = 0
	}

	spawn_enemies(&g)

	return g
}

// -------------------------------------------------------
// Combat helpers
// -------------------------------------------------------

try_fire :: proc(g: ^Game, src: Vector2, dir: Vector2, from_player: bool) {
	// find free bullet
	for i in 0 ..< MAX_BULLETS {
		if !g.bullets[i].alive {
			g.bullets[i].alive = true
			g.bullets[i].pos = src
			speed: f32 = cast(f32)BULLET_SPEED
			if !from_player {
				speed = cast(f32)(BULLET_SPEED * 0.8)
			}
			g.bullets[i].vel = scale(norm(dir), speed)
			g.bullets[i].from_player = from_player
			break
		}
	}
}

// -------------------------------------------------------
// Update
// -------------------------------------------------------

update_units :: proc(g: ^Game, dt: f32, mouse_world: Vector2, shooting: bool) {
	// reset targeting flags each frame
	for i in 0 ..< MAX_ENEMIES {g.enemies[i].targeted = false}
	// Auto-fire at nearest enemy in range; right mouse fires towards cursor
	for i in 0 ..< MAX_UNITS {
		u := &g.units[i]
		if !u.alive do continue
		// Path following
		if u.path_idx < u.path_len {
			wp := u.path[u.path_idx]
			wp_pos := grid_to_screen(wp.x, wp.y)
			delta := sub(wp_pos, u.pos)
			dist := vlen(delta)
			if dist < 4 {
				u.path_idx += 1
				u.vel = v2(0, 0)
			} else {
				u.vel = scale(norm(delta), PLAYER_SPEED)
				u.pos = add(u.pos, scale(u.vel, dt))
			}
		}

		// Combat
		if u.fire_cooldown > 0 do u.fire_cooldown -= dt

		if shooting && u.fire_cooldown <= 0 {
			dir := sub(mouse_world, u.pos)
			try_fire(g, add(u.pos, scale(norm(dir), UNIT_RADIUS + 2)), dir, true)
			u.fire_cooldown = FIRE_COOLDOWN
		} else if u.fire_cooldown <= 0 {
			// Auto target nearest within 220 px
			closest := -1
			closest_d2: f32 = 1e12
			for i in 0 ..< MAX_ENEMIES {
				if !g.enemies[i].alive do continue
				d := sub(g.enemies[i].pos, u.pos)
				d2: f32 = d.x * d.x + d.y * d.y
				if d2 < cast(f32)(220 * 220) && d2 < closest_d2 {closest = i;closest_d2 = d2}
			}
			if closest >= 0 {
				g.enemies[closest].targeted = true
				dir := sub(g.enemies[closest].pos, u.pos)
				try_fire(g, add(u.pos, scale(norm(dir), UNIT_RADIUS + 2)), dir, true)
				u.fire_cooldown = FIRE_COOLDOWN
			}
		}
	}
}

update_enemies :: proc(g: ^Game, dt: f32) {
	// Very simple: enemies drift toward average player position
	avg := v2(0, 0)
	alive_units := 0
	for i in 0 ..< MAX_UNITS {if g.units[i].alive {avg = add(avg, g.units[i].pos);alive_units += 1}}
	if alive_units > 0 do avg = scale(avg, 1.0 / cast(f32)alive_units)

	for i in 0 ..< MAX_ENEMIES {
		e := &g.enemies[i]
		if !e.alive do continue
		if alive_units > 0 {
			dir := sub(avg, e.pos)
			e.pos = add(e.pos, scale(norm(dir), ENEMY_SPEED * dt))
		}
	}
}

update_bullets :: proc(g: ^Game, dt: f32) {
	for i in 0 ..< MAX_BULLETS {
		b := &g.bullets[i]
		if !b.alive do continue
		b.pos = add(b.pos, scale(b.vel, dt))
		if b.pos.x < 0 || b.pos.y < 0 || b.pos.x >= SCREEN_W || b.pos.y >= SCREEN_H {
			b.alive = false
			continue
		}
		// Collide with enemies or players
		if b.from_player {
			for j in 0 ..< MAX_ENEMIES {
				e := &g.enemies[j]
				if !e.alive do continue
				d := sub(e.pos, b.pos)
				if (d.x * d.x + d.y * d.y) <=
				   (ENEMY_RADIUS + BULLET_RADIUS) * (ENEMY_RADIUS + BULLET_RADIUS) {
					e.alive = false
					b.alive = false
					break
				}
			}
		} else {
			for j in 0 ..< MAX_UNITS {
				u := &g.units[j]
				if !u.alive do continue
				d := sub(u.pos, b.pos)
				if (d.x * d.x + d.y * d.y) <=
				   (UNIT_RADIUS + BULLET_RADIUS) * (UNIT_RADIUS + BULLET_RADIUS) {
					u.alive = false
					b.alive = false
					break
				}
			}
		}
	}
}

// -------------------------------------------------------
// Rendering
// -------------------------------------------------------

set_draw_color :: proc(renderer: ^sdl.Renderer, r, g, b, a: u8) {
	sdl.SetRenderDrawColor(renderer, r, g, b, a)
}

fill_rect :: proc(renderer: ^sdl.Renderer, x, y, w, h: i32) {
	rect := sdl.Rect{x, y, w, h}
	sdl.RenderFillRect(renderer, &rect)
}

fill_circle :: proc(renderer: ^sdl.Renderer, cx, cy, radius: i32) {
	// naive filled circle
	for dy in -radius ..= radius {
		for dx in -radius ..= radius {
			if dx * dx + dy * dy <= radius * radius {
				sdl.RenderDrawPoint(renderer, cx + dx, cy + dy)
			}
		}
	}
}

// Box helpers
fill_box :: proc(renderer: ^sdl.Renderer, cx, cy, half: i32) {
	rect := sdl.Rect{cx - half, cy - half, half * 2, half * 2}
	sdl.RenderFillRect(renderer, &rect)
}

draw_box :: proc(renderer: ^sdl.Renderer, cx, cy, half: i32) {
	rect := sdl.Rect{cx - half, cy - half, half * 2, half * 2}
	sdl.RenderDrawRect(renderer, &rect)
}

point_in_rect :: proc(p: Vector2, x, y, w, h: i32) -> bool {
	return(
		p.x >= cast(f32)x &&
		p.x < cast(f32)(x + w) &&
		p.y >= cast(f32)y &&
		p.y < cast(f32)(y + h) \
	)
}

render :: proc(g: ^Game, renderer: ^sdl.Renderer, mouse_world: Vector2) {
	// Clear
	set_draw_color(renderer, 18, 18, 24, 255)
	sdl.RenderClear(renderer)

	// Tiles
	for y in 0 ..< GRID_H do for x in 0 ..< GRID_W {
		tile := g.world.tiles[y * GRID_W + x]
		switch tile {
		case .Sand:
			// Beige sand
			set_draw_color(renderer, 222, 205, 135, 255)
		case .Wood:
			// Green wood/forest
			set_draw_color(renderer, 60, 140, 60, 255)
		case .Water:
			// Blue water
			set_draw_color(renderer, 60, 120, 200, 255)
		}
		fill_rect(renderer, cast(i32)(x * TILE_SIZE), cast(i32)(y * TILE_SIZE), TILE_SIZE, TILE_SIZE)
	}

	// Path debug & units
	for i in 0 ..< MAX_UNITS {
		if !g.units[i].alive do continue
		// path
		set_draw_color(renderer, 90, 120, 255, 160)
		for j in g.units[i].path_idx ..< g.units[i].path_len {
			wp := g.units[i].path[j]
			p := grid_to_screen(wp.x, wp.y)
			fill_rect(renderer, cast(i32)p.x - 2, cast(i32)p.y - 2, 4, 4)
		}
	}

	// enemies
	for i in 0 ..< MAX_ENEMIES {
		if !g.enemies[i].alive do continue
		set_draw_color(renderer, 210, 70, 70, 255) // red
		fill_circle(
			renderer,
			cast(i32)g.enemies[i].pos.x,
			cast(i32)g.enemies[i].pos.y,
			ENEMY_RADIUS,
		)
		if g.enemies[i].targeted {
			set_draw_color(renderer, 255, 40, 40, 255)
			fill_circle(renderer, cast(i32)g.enemies[i].pos.x, cast(i32)g.enemies[i].pos.y, 3)
		}
	}

	// bullets
	for i in 0 ..< MAX_BULLETS {
		if !g.bullets[i].alive do continue
		if g.bullets[i].from_player {set_draw_color(renderer, 240, 240, 180, 255)} else {set_draw_color(renderer, 255, 150, 150, 255)}
		fill_circle(
			renderer,
			cast(i32)g.bullets[i].pos.x,
			cast(i32)g.bullets[i].pos.y,
			BULLET_RADIUS,
		)
	}

	// units last so they sit on top
	for i in 0 ..< MAX_UNITS {
		if !g.units[i].alive do continue
		set_draw_color(renderer, 80, 150, 255, 255) // blue
		fill_circle(renderer, cast(i32)g.units[i].pos.x, cast(i32)g.units[i].pos.y, UNIT_RADIUS)
	}

	// UI: Quit button (top-left)
	// Button background
	set_draw_color(renderer, 200, 60, 60, 255)
	fill_rect(renderer, QUIT_BTN_X, QUIT_BTN_Y, QUIT_BTN_W, QUIT_BTN_H)
	// Button border
	set_draw_color(renderer, 255, 255, 255, 255)
	// Draw border using 1px rectangles
	fill_rect(renderer, QUIT_BTN_X, QUIT_BTN_Y, QUIT_BTN_W, 1)
	fill_rect(renderer, QUIT_BTN_X, QUIT_BTN_Y + QUIT_BTN_H - 1, QUIT_BTN_W, 1)
	fill_rect(renderer, QUIT_BTN_X, QUIT_BTN_Y, 1, QUIT_BTN_H)
	fill_rect(renderer, QUIT_BTN_X + QUIT_BTN_W - 1, QUIT_BTN_Y, 1, QUIT_BTN_H)

	// Draw "Quit" text using simple rectangles
	text_x := cast(i32)(QUIT_BTN_X + 12) // Start position for text
	text_y := cast(i32)(QUIT_BTN_Y + 8) // Vertical center
	char_w := cast(i32)(3) // Character width
	char_h := cast(i32)(12) // Character height
	spacing := cast(i32)(6) // Space between characters

	// Q - draw a rectangle with a gap at bottom-right
	fill_rect(renderer, text_x, text_y, char_w, char_h - 2)
	fill_rect(renderer, text_x, text_y, 8, 2)
	fill_rect(renderer, text_x, text_y + char_h - 2, 8, 2)
	fill_rect(renderer, text_x + 6, text_y, char_w, char_h - 2)
	fill_rect(renderer, text_x + 4, text_y + 8, 4, 4)

	text_x += spacing + 3
	// U - draw left and right sides with bottom
	fill_rect(renderer, text_x, text_y, char_w, char_h)
	fill_rect(renderer, text_x, text_y + char_h - 2, 8, 2)
	fill_rect(renderer, text_x + 6, text_y, char_w, char_h)

	text_x += spacing + 3
	// I - simple vertical line
	fill_rect(renderer, text_x + 2, text_y, char_w, char_h)

	text_x += spacing
	// T - horizontal top line and vertical center line
	fill_rect(renderer, text_x, text_y, 8, 2)
	fill_rect(renderer, text_x + 2, text_y, char_w, char_h)

	// cursor
	set_draw_color(renderer, 255, 255, 255, 200)
	fill_circle(renderer, cast(i32)mouse_world.x, cast(i32)mouse_world.y, 3)

	sdl.RenderPresent(renderer)
}

// -------------------------------------------------------
// Input helpers
// -------------------------------------------------------

get_mouse_world :: proc(window: ^sdl.Window) -> Vector2 {
	mx, my: i32
	sdl.GetMouseState(&mx, &my)
	return v2(cast(f32)mx, cast(f32)my)
}

issue_move_command :: proc(g: ^Game, target: Vector2) {
	gx, gy := screen_to_grid(target)
	for i in 0 ..< MAX_UNITS {
		u := &g.units[i]
		if !u.alive do continue
		sx, sy := screen_to_grid(u.pos)
		u.path_len = find_path(g, sx, sy, gx, gy, &u.path)
		u.path_idx = 0
		u.target = target
	}
}

// -------------------------------------------------------
// Main loop
// -------------------------------------------------------

main :: proc() {
	if sdl.Init(sdl.INIT_VIDEO | sdl.INIT_EVENTS) != 0 {
		fmt.eprintln("SDL_Init error: %s", sdl.GetError())
		return
	}
	defer sdl.Quit()

	window := sdl.CreateWindow(
		"Cannon Fodder — Odin prototype",
		sdl.WINDOWPOS_CENTERED,
		sdl.WINDOWPOS_CENTERED,
		SCREEN_W,
		SCREEN_H,
		sdl.WINDOW_SHOWN,
	)
	if window == nil {
		fmt.eprintln("Window error: %s", sdl.GetError())
		return
	}
	defer sdl.DestroyWindow(window)

	renderer := sdl.CreateRenderer(
		window,
		-1,
		sdl.RENDERER_ACCELERATED | sdl.RENDERER_PRESENTVSYNC,
	)
	if renderer == nil {
		fmt.eprintln("Renderer error: %s", sdl.GetError())
		return
	}
	defer sdl.DestroyRenderer(renderer)

	g := init_game()

	running := true
	accumulator: f32 = 0
	last_ticks: u32 = sdl.GetTicks()

	shooting := false

	for running {
		// timing
		now_ticks := sdl.GetTicks()
		frame_time := cast(f32)(now_ticks - last_ticks) / 1000.0
		if frame_time > 0.25 {frame_time = 0.25} 	// avoid spiral of death
		last_ticks = now_ticks
		accumulator += frame_time

		// input
		ev: sdl.Event
		for sdl.PollEvent(&ev) != false {
			#partial switch ev.type {
			case .QUIT:
				running = false
			case .MOUSEBUTTONDOWN:
				if ev.button.button == sdl.BUTTON_LEFT {
					// Check quit button first
					mw := get_mouse_world(window)
					if point_in_rect(mw, QUIT_BTN_X, QUIT_BTN_Y, QUIT_BTN_W, QUIT_BTN_H) {
						running = false
					} else {
						issue_move_command(&g, mw)
					}
				} else if ev.button.button == sdl.BUTTON_RIGHT {
					shooting = true
				}
			case .MOUSEBUTTONUP:
				if ev.button.button == sdl.BUTTON_RIGHT {shooting = false}
			}
		}

		// fixed step updates
		for accumulator >= DT {
			mouse_world := get_mouse_world(window)
			update_units(&g, DT, mouse_world, shooting)
			update_enemies(&g, DT)
			update_bullets(&g, DT)
			accumulator -= DT
		}

		// render
		render(&g, renderer, get_mouse_world(window))

		// enemy stray fire (adds pressure)
		// occasional random bullets from enemies toward average player
		if rng_random_between(&g.rng, 0.0, 1.0) < 0.03 {
			avg := v2(0, 0);alive := 0
			for i in 0 ..< MAX_UNITS {if g.units[i].alive {avg = add(avg, g.units[i].pos);alive += 1}}
			if alive > 0 {
				avg = scale(avg, 1.0 / cast(f32)alive)
				// pick a random alive enemy
				idx := -1
				for i in 0 ..< MAX_ENEMIES {if g.enemies[i].alive {idx = i;break}}
				if idx >= 0 {
					dir := sub(avg, g.enemies[idx].pos)
					try_fire(&g, g.enemies[idx].pos, dir, false)
				}
			}
		}
	}
}
