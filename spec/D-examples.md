# Appendix D. Example Programs (informative)

Each example is a complete module and is intended to compile under this specification.
The examples double as seed cases for the conformance suite (B.9).

## D.1 Hello

```pyro
// src/main.pr
struct Vec2 { x: f32, y: f32 }

pub fn main() {
    print("Hello from Pyro\n");
    let pos = Vec2 { x: 10.0, y: 20.0 };
    print("x = {}, y = {}\n", pos.x, pos.y);
}
```

## D.2 Particles: SoA, parallel loops, GPU

```pyro
// src/main.pr
use std.math;

@soa
pub struct Particle {
    pub mut x: f32,
    pub mut y: f32,
    pub mut vx: f32,
    pub mut vy: f32,
}

/// Multithreaded: every iteration writes only its own element.
fn apply_drag(mut ps: []Particle, k: f32) {
    parallel_for p in ps {
        p.vx *= k;
        p.vy *= k;
    }
}

/// Runs on the GPU, or as a vectorized CPU loop when no GPU is available.
@gpu_kernel(workgroup: 64)
fn integrate(mut ps: []Particle, dt: f32) {
    let i = @global_invocation_id.x as usize;
    if i >= ps.len() { return; }
    ps[i].x += ps[i].vx * dt;
    ps[i].y += ps[i].vy * dt;
}

fn kinetic_energy(ps: []Particle) -> f32 {
    let mut e: f32 = 0.0;
    for p in ps where p.vx > 0.0 {     // only particles moving right
        e += 0.5 * (p.vx * p.vx + p.vy * p.vy);
    }
    e
}

pub fn main() {
    let mut ps: List<Particle> = .init();
    defer ps.deinit();

    for i in 0..10_000 {
        let f = i as f32;
        ps.push(.{ x: f, y: 0.0, vx: math.sin(f), vy: math.cos(f) });
    }
    for _ in 0..100 {
        apply_drag(mut ps[..], 0.99);
        launch gpu integrate(mut ps[..], 0.016);
    }
    print("energy: {}\n", kinetic_energy(ps[..]));
}
```

Notes: `Particle` is `@soa`, so `List<Particle>` stores four `f32` columns, and `[]Particle`
is a SoA view. `p.vx *= k` writes to the `vx` column. `ps[..]` on a mutable `List`
gives a mutable view, which `mut` passes on.

## D.3 Parse, don't validate

```pyro
// src/net/port.pr
pub enum PortError { zero, too_large(u32) }

impl Display for PortError {
    fn fmt(self, mut w: std.fmt.Writer) {
        match self {
            .zero => w.write("port 0 is reserved"),
            .too_large(v) => {
                w.write("port ");
                w.write_uint(v as u64);
                w.write(" is above 65535");
            }
        }
    }
}

/// Only `parse_port` can create a `Port`: `value` is readable but not writable outside
/// this module, and has no default.
pub struct Port { pub value: u16 }

pub fn parse_port(raw: u32) -> Result<Port, PortError> {
    if raw == 0 { return .err(.zero); }
    if raw > 65535 { return .err(.too_large(raw)); }
    return .ok(Port { value: raw as u16 });
}
```

```pyro
// src/main.pr
use net.port.{parse_port, Port, PortError};

fn listen(port: Port) {               // no re-validation needed here
    print("listening on {}\n", port.value);
}

pub fn main() -> Result<void, PortError> {
    let port = parse_port(8080)?;
    listen(port);
    return .ok();
}
```

## D.4 A generic container with contracts, tests and a law

```pyro
// src/ring.pr
@invariant(self.count <= CAP)
pub struct Ring<T, CAP: usize> {
    items: [CAP]T,
    head: usize = 0,
    count: usize = 0,

    pub fn init() -> Self {
        Self { items: [@zero(T); CAP], .. }       // head and count use their defaults
    }

    pub fn len(self) -> usize { self.count }

    /// Appends `v`; when full, overwrites the oldest element.
    @requires(CAP > 0)
    pub fn push(mut self, v: T) {
        let tail = (self.head + self.count) % CAP;
        self.items[tail] = v;
        if self.count == CAP {
            self.head = (self.head + 1) % CAP;
        } else {
            self.count += 1;
        }
    }

    @ensures(result.is_none() || self.count == @old(self.count) - 1)
    pub fn pop(mut self) -> Option<T> {
        if self.count == 0 { return .none; }
        let v = self.items[self.head];
        self.head = (self.head + 1) % CAP;
        self.count -= 1;
        return .some(v);
    }
}

@test
fn ring_overwrites_oldest() {
    let mut r: Ring<u8, 3> = .init();
    for i in 0..5 { r.push(i as u8); }
    assert(r.len() == 3, "capacity respected");
    assert(r.pop() == .some(2), "oldest surviving element is 2");
}

/// Proved exhaustively by `pyro test`: a u8 domain has 256 inputs.
@law
fn push_then_pop_returns_value(x: u8) -> bool {
    let mut r: Ring<u8, 4> = .init();
    r.push(x);
    r.pop() == .some(x)
}
```

## D.5 Comptime reflection

```pyro
// src/debug_dump.pr
use std.meta;

/// Prints every field of any struct value. The loop is unrolled at compile time.
pub fn dump<T>(v: T) {
    print("{} {{\n", @type_name(T));
    inline for f in meta.fields(T) {
        print("  {} = {:?}\n", f.name, @field(v, f.name));
    }
    print("}}\n");
}

/// A compile-time layout check.
comptime {
    if @size_of(std.mem.HeapStats) > 64 {
        @compile_error("HeapStats must fit one cache line");
    }
}
```

## D.6 Beginner tables and what `--expand` shows

```pyro
// src/main.pr
use std.data.{Table};

pub struct Monster {
    pub mut health: f32,
    pub mut threat: u32,
    pub mut name: u64,
}

const Monsters = Table(Monster, .{ sorted_by: .threat, .. });

pub fn main() {
    let mut monsters: Monsters = .init();
    defer monsters.deinit();

    monsters.add(.{ health: 100.0, threat: 3, name: @hash("orc") });
    monsters.add(.{ health: 50.0,  threat: 8, name: @hash("troll") });

    for m in monsters where m.health > 75.0 {
        print("threat {}\n", m.threat);
    }
}
```

`pyro build --expand` prints (abridged: the generated `Table__Monster__…` declaration
is elided):

```pyro
pub fn main() {
    let mut monsters: Table__Monster__sorted_by_threat = Table__Monster__sorted_by_threat.init();
    defer monsters.deinit();

    monsters.add(Monster { health: 100.0, threat: 3, name: 0x19fb901921bfa625 });
    monsters.add(Monster { health: 50.0, threat: 8, name: 0x35752ba6f609925c });

    {
        let __n: usize = monsters.len();
        let mut __i: usize = 0;
        while __i < __n {
            let m = monsters.at(__i);              // Indexable.at (a copy of the element)
            if !(m.health > 75.0) { __i += 1; continue; }
            print("threat {}\n", m.threat);
            __i += 1;
        }
    }
}
```

Every loop, branch and allocation is visible. The "script-like" source contained no
hidden runtime machinery (principle 2).

## D.7 Broadphase collision with a scratch arena

```pyro
// src/collide.pr
@soa
pub struct Body {
    pub mut x: f32,
    pub mut y: f32,
    pub mut active: bool,
    pub mut layer: u7,
}
pub struct Pair { pub mut a: u32, pub mut b: u32 }
pub enum CollideError { buffer_full }

const GRID: u32 = 64;

/// Writes candidate pairs into `out` and returns how many were written.
pub fn broadphase(
    mut scratch: Arena,
    bodies: []Body,
    cell: f32,
    mut out: []Pair,
) -> Result<usize, CollideError> {
    defer scratch.reset();                         // runs after the last use of head/next

    let mut head = scratch.alloc_slice(i32, (GRID * GRID) as usize);
    let mut next = scratch.alloc_slice(i32, bodies.len());   // append-only: head stays valid
    head.fill(-1);

    for b, i in bodies where b.active {
        let gx = ((b.x / cell) as u32) & (GRID - 1);
        let gy = ((b.y / cell) as u32) & (GRID - 1);
        let c = (gy * GRID + gx) as usize;
        next[i] = head[c];
        head[c] = i as i32;
    }

    let mut found: usize = 0;
    for c in 0..(GRID * GRID) as usize {
        let mut i = head[c];
        while i != -1 {
            let ui = i as usize;
            let mut j = next[ui];
            while j != -1 {
                let uj = j as usize;
                if bodies[ui].layer == bodies[uj].layer {
                    let dx = bodies[ui].x - bodies[uj].x;
                    let dy = bodies[ui].y - bodies[uj].y;
                    if dx * dx + dy * dy < cell * cell {
                        if found >= out.len() { return .err(.buffer_full); }
                        out[found] = .{ a: ui as u32, b: uj as u32 };
                        found += 1;
                    }
                }
                j = next[uj];
            }
            i = next[ui];
        }
    }
    return .ok(found);
}
```

## D.8 Structured concurrency with a channel

```pyro
// src/main.pr
enum Job { compress(u32) }

fn worker(jobs: Channel<Job, 64>, done: Atomic<u64>) {
    while let .some(job) = jobs.recv() {          // ends when all senders are released
        match job {
            .compress(id) => { _ = done.fetch_add(id as u64); },
        }
    }
}

fn produce(move tx: Sender<Job>) {
    defer tx.close();                              // required: tx is a resource
    for id in 1..=100u32 { _ = tx.send(.compress(id)); }
}

pub fn main() {
    let mut jobs: Channel<Job, 64> = .init();
    defer jobs.deinit();
    let done: Atomic<u64> = .init(0);
    let tx = jobs.sender();                        // create senders before consumers start

    nursery {
        for _ in 0..4 { spawn worker(jobs, done); }   // read-only views: shared safely
        spawn produce(move tx);
    }
    print("checksum {}\n", done.load());
}
```

`jobs` and `done` are passed read-only to every task. That is allowed because `Channel`
receive operations and `Atomic` methods synchronize internally (§10.4, §10.5). `done` is
a shared cell (§5.1): it is not copied into the tasks, and it needs no release. When
`produce` returns, its `defer` closes the only sender, so each worker's `recv` returns
`.none` after the queue drains, and the nursery joins. The channel graph
(main → produce → workers) is acyclic, so no W0501 is reported.
