use std::collections::{HashMap, HashSet, VecDeque};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};
use std::process::Command;
use std::time::{Duration, Instant};

use crossbeam_channel::{bounded, Receiver};
use pnet::datalink::{self, Channel::Ethernet};
use pnet::packet::ethernet::{EtherTypes, EthernetPacket};
use pnet::packet::ip::IpNextHeaderProtocols;
use pnet::packet::ipv4::Ipv4Packet;
use pnet::packet::ipv6::Ipv6Packet;
use pnet::packet::tcp::TcpPacket;
use pnet::packet::udp::UdpPacket;
use pnet::packet::Packet;
use winit::dpi::{PhysicalPosition, PhysicalSize};
use winit::event::{Event, WindowEvent};
use winit::event_loop::EventLoop;
use winit::window::{Window, WindowBuilder, WindowLevel};

const WINDOW_WIDTH: u32 = 900;
const WINDOW_HEIGHT: u32 = 600;
const MAX_PARTICLES: usize = 2000;
const PARTICLE_SIZE: f32 = 6.0;
const IDLE_FADE_MS: u128 = 200;

const FAST_UDP_WINDOW_MS: u128 = 150;
const FAST_UDP_MAX_LEN: u16 = 192;
const UDP_FAST_PORTS: &[u16] = &[53, 5353, 443, 3478, 5349, 1900];

fn classify_tcp_port(port: u16) -> Option<Proto> {
    match port {
        80 => Some(Proto::Http),
        443 => Some(Proto::Https),
        22 => Some(Proto::Ssh),
        _ => None,
    }
}

fn classify_udp_port(port: u16) -> Option<Proto> {
    match port {
        53 => Some(Proto::Dns),
        5353 => Some(Proto::Mdns),
        443 => Some(Proto::Quic),
        67 | 68 => Some(Proto::Dhcp),
        123 => Some(Proto::Ntp),
        1900 => Some(Proto::Ssdp),
        3478 => Some(Proto::Stun),
        5349 => Some(Proto::Turn),
        _ => None,
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
enum Proto {
    Tcp,
    Http,
    Https,
    Ssh,
    Udp,
    Dns,
    Mdns,
    Quic,
    Dhcp,
    Ntp,
    Ssdp,
    Stun,
    Turn,
    Icmp,
    Icmpv6,
    Arp,
    Other,
}

#[derive(Debug, Clone, Copy)]
enum Direction {
    In,
    Out,
    None,
}

#[derive(Clone, Copy)]
struct PacketEvent {
    proto: Proto,
    direction: Direction,
    fast: bool,
}

#[derive(Clone, Copy)]
struct Particle {
    x: f32,
    y: f32,
    vy: f32,
    color: [f32; 4],
}

#[repr(C)]
#[derive(Clone, Copy, bytemuck::Pod, bytemuck::Zeroable)]
struct Vertex {
    pos: [f32; 2],
    color: [f32; 4],
}

impl Vertex {
    fn desc() -> wgpu::VertexBufferLayout<'static> {
        wgpu::VertexBufferLayout {
            array_stride: std::mem::size_of::<Vertex>() as wgpu::BufferAddress,
            step_mode: wgpu::VertexStepMode::Vertex,
            attributes: &[
                wgpu::VertexAttribute {
                    offset: 0,
                    shader_location: 0,
                    format: wgpu::VertexFormat::Float32x2,
                },
                wgpu::VertexAttribute {
                    offset: std::mem::size_of::<[f32; 2]>() as wgpu::BufferAddress,
                    shader_location: 1,
                    format: wgpu::VertexFormat::Float32x4,
                },
            ],
        }
    }
}

struct Sniffer {
    rx: Receiver<PacketEvent>,
}

impl Sniffer {
    fn new(interface: datalink::NetworkInterface) -> Result<Self, String> {
        let (tx, rx) = bounded(10000);
        let local_ipv4s: HashSet<Ipv4Addr> = interface
            .ips
            .iter()
            .filter_map(|ip| {
                if let pnet::ipnetwork::IpNetwork::V4(v4) = ip {
                    Some(v4.ip())
                } else {
                    None
                }
            })
            .collect();
        let local_ipv6s: HashSet<Ipv6Addr> = interface
            .ips
            .iter()
            .filter_map(|ip| {
                if let pnet::ipnetwork::IpNetwork::V6(v6) = ip {
                    Some(v6.ip())
                } else {
                    None
                }
            })
            .collect();

        let channel_result = datalink::channel(&interface, Default::default())
            .map_err(|e| e.to_string())?;

        match channel_result {
            Ethernet(_tx, mut rx_iter) => {
                std::thread::spawn(move || {
                    let mut udp_recent: HashMap<(IpAddr, u16, IpAddr, u16), Instant> =
                        HashMap::with_capacity(2048);
                    loop {
                        match rx_iter.next() {
                            Ok(packet) => {
                                if let Some(eth) = EthernetPacket::new(packet) {
                                    let (proto, direction, fast) = match eth.get_ethertype() {
                                        EtherTypes::Ipv4 => {
                                            if let Some(ip) = Ipv4Packet::new(eth.payload()) {
                                                let src = IpAddr::V4(ip.get_source());
                                                let dst = IpAddr::V4(ip.get_destination());
                                                let mut proto = match ip.get_next_level_protocol() {
                                                    IpNextHeaderProtocols::Tcp => Proto::Tcp,
                                                    IpNextHeaderProtocols::Udp => Proto::Udp,
                                                    IpNextHeaderProtocols::Icmp => Proto::Icmp,
                                                    _ => Proto::Other,
                                                };
                                                let dest = ip.get_destination();
                                                let direction = if local_ipv4s.contains(&dest) {
                                                    Direction::In
                                                } else {
                                                    Direction::Out
                                                };
                                                let mut fast = false;
                                                if let Some(tcp) = TcpPacket::new(ip.payload()) {
                                                    let flags = tcp.get_flags();
                                                    let syn = flags & 0x02 != 0;
                                                    let fin = flags & 0x01 != 0;
                                                    let rst = flags & 0x04 != 0;
                                                    let ack = flags & 0x10 != 0;
                                                    let small_payload = tcp.payload().len() <= 32;
                                                    if syn || fin || rst || (ack && small_payload) {
                                                        fast = true;
                                                    }
                                                    if let Some(p) = classify_tcp_port(tcp.get_source()) {
                                                        proto = p;
                                                    }
                                                    if let Some(p) = classify_tcp_port(tcp.get_destination()) {
                                                        proto = p;
                                                    }
                                                } else if let Some(udp) = UdpPacket::new(ip.payload()) {
                                                    let key = (src, udp.get_source(), dst, udp.get_destination());
                                                    let rev = (dst, udp.get_destination(), src, udp.get_source());
                                                    let now = Instant::now();
                                                    if let Some(prev) = udp_recent.get(&rev) {
                                                        if now.duration_since(*prev).as_millis()
                                                            <= FAST_UDP_WINDOW_MS
                                                        {
                                                            fast = true;
                                                        }
                                                    }
                                                    let udp_len = udp.get_length();
                                                    let port_hit = UDP_FAST_PORTS.contains(&udp.get_destination())
                                                        || UDP_FAST_PORTS.contains(&udp.get_source());
                                                    if udp_len <= FAST_UDP_MAX_LEN && port_hit {
                                                        fast = true;
                                                    }
                                                    if let Some(p) = classify_udp_port(udp.get_source()) {
                                                        proto = p;
                                                    }
                                                    if let Some(p) = classify_udp_port(udp.get_destination()) {
                                                        proto = p;
                                                    }
                                                    udp_recent.insert(key, now);
                                                    if udp_recent.len() > 4096 {
                                                        let cutoff = now - Duration::from_secs(2);
                                                        udp_recent.retain(|_, t| *t >= cutoff);
                                                    }
                                                }
                                                (proto, direction, fast)
                                            } else {
                                                (Proto::Other, Direction::None, false)
                                            }
                                        }
                                        EtherTypes::Ipv6 => {
                                            if let Some(ip6) = Ipv6Packet::new(eth.payload()) {
                                                let src = IpAddr::V6(ip6.get_source());
                                                let dst = IpAddr::V6(ip6.get_destination());
                                                let mut proto = match ip6.get_next_header() {
                                                    IpNextHeaderProtocols::Tcp => Proto::Tcp,
                                                    IpNextHeaderProtocols::Udp => Proto::Udp,
                                                    IpNextHeaderProtocols::Icmpv6 => Proto::Icmpv6,
                                                    _ => Proto::Other,
                                                };
                                                let dest = ip6.get_destination();
                                                let direction = if local_ipv6s.contains(&dest) {
                                                    Direction::In
                                                } else {
                                                    Direction::Out
                                                };
                                                let mut fast = false;
                                                if let Some(tcp) = TcpPacket::new(ip6.payload()) {
                                                    let flags = tcp.get_flags();
                                                    let syn = flags & 0x02 != 0;
                                                    let fin = flags & 0x01 != 0;
                                                    let rst = flags & 0x04 != 0;
                                                    let ack = flags & 0x10 != 0;
                                                    let small_payload = tcp.payload().len() <= 32;
                                                    if syn || fin || rst || (ack && small_payload) {
                                                        fast = true;
                                                    }
                                                    if let Some(p) = classify_tcp_port(tcp.get_source()) {
                                                        proto = p;
                                                    }
                                                    if let Some(p) = classify_tcp_port(tcp.get_destination()) {
                                                        proto = p;
                                                    }
                                                } else if let Some(udp) = UdpPacket::new(ip6.payload()) {
                                                    let key = (src, udp.get_source(), dst, udp.get_destination());
                                                    let rev = (dst, udp.get_destination(), src, udp.get_source());
                                                    let now = Instant::now();
                                                    if let Some(prev) = udp_recent.get(&rev) {
                                                        if now.duration_since(*prev).as_millis()
                                                            <= FAST_UDP_WINDOW_MS
                                                        {
                                                            fast = true;
                                                        }
                                                    }
                                                    let udp_len = udp.get_length();
                                                    let port_hit = UDP_FAST_PORTS.contains(&udp.get_destination())
                                                        || UDP_FAST_PORTS.contains(&udp.get_source());
                                                    if udp_len <= FAST_UDP_MAX_LEN && port_hit {
                                                        fast = true;
                                                    }
                                                    if let Some(p) = classify_udp_port(udp.get_source()) {
                                                        proto = p;
                                                    }
                                                    if let Some(p) = classify_udp_port(udp.get_destination()) {
                                                        proto = p;
                                                    }
                                                    udp_recent.insert(key, now);
                                                    if udp_recent.len() > 4096 {
                                                        let cutoff = now - Duration::from_secs(2);
                                                        udp_recent.retain(|_, t| *t >= cutoff);
                                                    }
                                                }
                                                (proto, direction, fast)
                                            } else {
                                                (Proto::Other, Direction::None, false)
                                            }
                                        }
                                        EtherTypes::Arp => (Proto::Arp, Direction::None, false),
                                        _ => (Proto::Other, Direction::None, false),
                                    };

                                    let _ = tx.send(PacketEvent {
                                        proto,
                                        direction,
                                        fast,
                                    });
                                }
                            }
                            Err(_) => break,
                        }
                    }
                });
                Ok(Sniffer { rx })
            }
            _ => Err("Unhandled channel type".to_string()),
        }
    }
}

fn get_interface() -> Option<datalink::NetworkInterface> {
    if let Ok(name) = std::env::var("TRAFFIC_IFACE") {
        return datalink::interfaces()
            .into_iter()
            .find(|iface| iface.name == name);
    }
    fn score(name: &str) -> i32 {
        if name.starts_with("en") || name.starts_with("eth") {
            4
        } else if name.starts_with('w') {
            3
        } else if name.starts_with("br") || name.starts_with("docker") || name.starts_with("veth") {
            0
        } else {
            2
        }
    }

    datalink::interfaces()
        .into_iter()
        .filter(|iface| !iface.is_loopback() && iface.is_up() && !iface.ips.is_empty())
        .max_by_key(|iface| score(&iface.name))
}

fn proto_color(proto: Proto) -> [f32; 4] {
    match proto {
        Proto::Tcp => [0.95, 0.55, 0.62, 0.95],
        Proto::Http => [0.98, 0.78, 0.55, 0.95],
        Proto::Https => [0.88, 0.65, 0.95, 0.95],
        Proto::Ssh => [0.72, 0.92, 0.76, 0.95],
        Proto::Udp => [0.54, 0.71, 0.98, 0.95],
        Proto::Dns => [0.62, 0.86, 0.98, 0.95],
        Proto::Mdns => [0.45, 0.8, 0.95, 0.95],
        Proto::Quic => [0.4, 0.75, 0.95, 0.95],
        Proto::Dhcp => [0.95, 0.9, 0.6, 0.95],
        Proto::Ntp => [0.8, 0.85, 0.95, 0.95],
        Proto::Ssdp => [0.95, 0.75, 0.5, 0.95],
        Proto::Stun => [0.6, 0.95, 0.85, 0.95],
        Proto::Turn => [0.55, 0.95, 0.7, 0.95],
        Proto::Icmp => [0.66, 0.9, 0.62, 0.95],
        Proto::Icmpv6 => [0.55, 0.85, 0.58, 0.95],
        Proto::Arp => [0.95, 0.7, 0.6, 0.95],
        Proto::Other => [0.75, 0.75, 0.8, 0.9],
    }
}

fn proto_lane(proto: Proto) -> usize {
    match proto {
        Proto::Tcp | Proto::Http | Proto::Https | Proto::Ssh => 0,
        Proto::Udp | Proto::Dns | Proto::Mdns | Proto::Quic | Proto::Dhcp | Proto::Ntp | Proto::Ssdp | Proto::Stun | Proto::Turn => 1,
        Proto::Icmp | Proto::Icmpv6 => 2,
        Proto::Arp | Proto::Other => 2,
    }
}

fn proto_offset(proto: Proto) -> f32 {
    match proto {
        Proto::Tcp => -0.15,
        Proto::Http => -0.25,
        Proto::Https => 0.05,
        Proto::Ssh => 0.22,
        Proto::Udp => 0.0,
        Proto::Dns => -0.2,
        Proto::Mdns => -0.32,
        Proto::Quic => 0.24,
        Proto::Dhcp => 0.12,
        Proto::Ntp => -0.05,
        Proto::Ssdp => 0.3,
        Proto::Stun => -0.12,
        Proto::Turn => 0.18,
        Proto::Icmp => -0.18,
        Proto::Icmpv6 => 0.18,
        Proto::Arp => 0.0,
        Proto::Other => 0.12,
    }
}

fn proto_speed(proto: Proto) -> f32 {
    match proto {
        Proto::Tcp => 1.0,
        Proto::Http => 1.1,
        Proto::Https => 0.95,
        Proto::Ssh => 1.05,
        Proto::Udp => 1.0,
        Proto::Dns => 1.2,
        Proto::Mdns => 1.15,
        Proto::Quic => 1.25,
        Proto::Dhcp => 1.1,
        Proto::Ntp => 1.1,
        Proto::Ssdp => 1.0,
        Proto::Stun => 1.2,
        Proto::Turn => 1.15,
        Proto::Icmp => 1.05,
        Proto::Icmpv6 => 1.05,
        Proto::Arp => 0.9,
        Proto::Other => 0.95,
    }
}

fn spawn_particle(
    particles: &mut VecDeque<Particle>,
    proto: Proto,
    direction: Direction,
    fast: bool,
    width: f32,
) {
    let lane_w = width / 3.0;
    let lane_idx = proto_lane(proto) as f32;

    let lane_x0 = lane_idx * lane_w;
    let lane_x1 = lane_x0 + lane_w;
    let mut x = (lane_x0 + lane_x1) * 0.5;
    let jitter = (lane_w * 0.25) * (rand_unit() - 0.5);

    match direction {
        Direction::In => x = lane_x0 + lane_w * 0.33,
        Direction::Out => x = lane_x0 + lane_w * 0.66,
        Direction::None => {}
    }

    x += lane_w * proto_offset(proto);

    x = (x + jitter).clamp(lane_x0 + 6.0, lane_x1 - 6.0);

    let base_speed = if fast { 360.0 } else { 180.0 };
    let vy = (base_speed + 120.0 * rand_unit()) * proto_speed(proto);

    particles.push_back(Particle {
        x,
        y: -10.0,
        vy,
        color: proto_color(proto),
    });
    if particles.len() > MAX_PARTICLES {
        particles.pop_front();
    }
}


fn rand_unit() -> f32 {
    use std::cell::Cell;
    thread_local! {
        static SEED: Cell<u32> = Cell::new(0x12345678);
    }
    SEED.with(|s| {
        let mut v = s.get();
        v ^= v << 13;
        v ^= v >> 17;
        v ^= v << 5;
        s.set(v);
        (v as f32 / u32::MAX as f32).max(0.0001)
    })
}

fn main() {
    let interface = match get_interface() {
        Some(i) => i,
        None => {
            eprintln!("No interface found");
            return;
        }
    };
    eprintln!("Using interface: {}", interface.name);

    let sniffer = match Sniffer::new(interface) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("Sniffer error: {e} (run with sudo)");
            return;
        }
    };

    let event_loop = EventLoop::new().unwrap();
    let window = WindowBuilder::new()
        .with_title("Traffic Rain")
        .with_inner_size(PhysicalSize::new(WINDOW_WIDTH, WINDOW_HEIGHT))
        .with_resizable(true)
        .build(&event_loop)
        .unwrap();

    window.set_window_level(WindowLevel::AlwaysOnTop);

    if let Some(monitor) = window.current_monitor() {
        let size = monitor.size();
        let x = (size.width.saturating_sub(WINDOW_WIDTH)) / 2;
        let y = (size.height.saturating_sub(WINDOW_HEIGHT)) / 2;
        window.set_outer_position(PhysicalPosition::new(x as i32, y as i32));
    }

    if std::env::var("HYPRLAND_INSTANCE_SIGNATURE").is_ok() {
        let _ = Command::new("hyprctl")
            .args(["dispatch", "movetoworkspacesilent", "special"])
            .status();
    }

    pollster::block_on(run(window, sniffer, event_loop));
}

async fn run(window: Window, sniffer: Sniffer, event_loop: EventLoop<()>) {
    if std::env::var("WAYLAND_DISPLAY").is_err() && std::env::var("DISPLAY").is_err() {
        eprintln!("No WAYLAND_DISPLAY or DISPLAY found. If running with sudo, try: sudo -E cargo run --bin traffic_gui");
        return;
    }
    let window = std::sync::Arc::new(window);
    let size = window.inner_size();

    let instance = wgpu::Instance::default();
    let surface = match instance.create_surface(std::sync::Arc::clone(&window)) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("Failed to create surface: {e:?}. If running with sudo, try: sudo -E cargo run --bin traffic_gui");
            return;
        }
    };
    let adapter = instance
        .request_adapter(&wgpu::RequestAdapterOptions {
            power_preference: wgpu::PowerPreference::HighPerformance,
            compatible_surface: Some(&surface),
            force_fallback_adapter: false,
        })
        .await
        .unwrap();

    let (device, queue) = adapter
        .request_device(&wgpu::DeviceDescriptor {
            label: None,
            required_features: wgpu::Features::empty(),
            required_limits: wgpu::Limits::default(),
            memory_hints: wgpu::MemoryHints::default(),
            trace: wgpu::Trace::Off,
            experimental_features: wgpu::ExperimentalFeatures::default(),
        })
        .await
        .unwrap();

    let surface_caps = surface.get_capabilities(&adapter);
    let surface_format = surface_caps.formats[0];

    let mut config = wgpu::SurfaceConfiguration {
        usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
        format: surface_format,
        width: size.width.max(1),
        height: size.height.max(1),
        present_mode: wgpu::PresentMode::Fifo,
        alpha_mode: surface_caps.alpha_modes[0],
        view_formats: vec![],
        desired_maximum_frame_latency: 2,
    };
    surface.configure(&device, &config);

    let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
        label: Some("traffic_shader"),
        source: wgpu::ShaderSource::Wgsl(include_str!("traffic_shader.wgsl").into()),
    });

    let pipeline_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
        label: Some("pipeline_layout"),
        bind_group_layouts: &[],
        immediate_size: 0,
    });

    let render_pipeline = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
        label: Some("render_pipeline"),
        layout: Some(&pipeline_layout),
        vertex: wgpu::VertexState {
            module: &shader,
            entry_point: Some("vs_main"),
            compilation_options: wgpu::PipelineCompilationOptions::default(),
            buffers: &[Vertex::desc()],
        },
        fragment: Some(wgpu::FragmentState {
            module: &shader,
            entry_point: Some("fs_main"),
            compilation_options: wgpu::PipelineCompilationOptions::default(),
            targets: &[Some(wgpu::ColorTargetState {
                format: surface_format,
                blend: Some(wgpu::BlendState::ALPHA_BLENDING),
                write_mask: wgpu::ColorWrites::ALL,
            })],
        }),
        primitive: wgpu::PrimitiveState::default(),
        depth_stencil: None,
        multisample: wgpu::MultisampleState::default(),
        multiview_mask: None,
        cache: None,
    });

    let max_vertices = MAX_PARTICLES * 6;
    let vertex_buffer = device.create_buffer(&wgpu::BufferDescriptor {
        label: Some("vertex_buffer"),
        size: (max_vertices * std::mem::size_of::<Vertex>()) as u64,
        usage: wgpu::BufferUsages::VERTEX | wgpu::BufferUsages::COPY_DST,
        mapped_at_creation: false,
    });

    let mut particles: VecDeque<Particle> = VecDeque::with_capacity(MAX_PARTICLES + 16);
    let mut last_frame = Instant::now();
    let mut last_packet = Instant::now();

    let window_for_redraw = window.clone();

    event_loop
        .run(move |event, elwt| {
            elwt.set_control_flow(winit::event_loop::ControlFlow::Poll);

            match event {
                Event::WindowEvent { event, .. } => match event {
                    WindowEvent::CloseRequested => elwt.exit(),
                    WindowEvent::Resized(new_size) => {
                        config.width = new_size.width.max(1);
                        config.height = new_size.height.max(1);
                        surface.configure(&device, &config);
                    }
                    WindowEvent::RedrawRequested => {
                        let now = Instant::now();
                        let dt = now.duration_since(last_frame).as_secs_f32();
                        last_frame = now;

                        while let Ok(pkt) = sniffer.rx.try_recv() {
                            spawn_particle(
                                &mut particles,
                                pkt.proto,
                                pkt.direction,
                                pkt.fast,
                                config.width as f32,
                            );
                            last_packet = Instant::now();
                        }

                        for p in particles.iter_mut() {
                            p.y += p.vy * dt;
                        }
                        while let Some(front) = particles.front() {
                            if front.y > config.height as f32 + 10.0 {
                                particles.pop_front();
                            } else {
                                break;
                            }
                        }

                        let mut vertices: Vec<Vertex> = Vec::with_capacity(particles.len() * 6);
                        for p in particles.iter() {
                            let half = PARTICLE_SIZE * 0.5;
                            let x0 = p.x - half;
                            let x1 = p.x + half;
                            let y0 = p.y - half;
                            let y1 = p.y + half;

                            let to_ndc = |x: f32, y: f32| -> [f32; 2] {
                                let nx = (x / config.width as f32) * 2.0 - 1.0;
                                let ny = 1.0 - (y / config.height as f32) * 2.0;
                                [nx, ny]
                            };

                            let c = p.color;
                            let v0 = Vertex { pos: to_ndc(x0, y0), color: c };
                            let v1 = Vertex { pos: to_ndc(x1, y0), color: c };
                            let v2 = Vertex { pos: to_ndc(x1, y1), color: c };
                            let v3 = Vertex { pos: to_ndc(x0, y1), color: c };

                            vertices.push(v0);
                            vertices.push(v1);
                            vertices.push(v2);
                            vertices.push(v0);
                            vertices.push(v2);
                            vertices.push(v3);
                        }

                        if !vertices.is_empty() {
                            queue.write_buffer(&vertex_buffer, 0, bytemuck::cast_slice(&vertices));
                        }

                        let frame = match surface.get_current_texture() {
                            Ok(f) => f,
                            Err(_) => {
                                surface.configure(&device, &config);
                                return;
                            }
                        };
                        let view = frame
                            .texture
                            .create_view(&wgpu::TextureViewDescriptor::default());

                        let mut encoder = device.create_command_encoder(&wgpu::CommandEncoderDescriptor {
                            label: Some("render_encoder"),
                        });

                        {
                        let idle = last_packet.elapsed().as_millis() >= IDLE_FADE_MS;
                        let clear = if idle {
                            wgpu::Color { r: 0.01, g: 0.01, b: 0.02, a: 1.0 }
                        } else {
                            wgpu::Color { r: 0.05, g: 0.05, b: 0.12, a: 1.0 }
                        };

                        let mut rpass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                            label: Some("render_pass"),
                            color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                                view: &view,
                                resolve_target: None,
                                ops: wgpu::Operations {
                                    load: wgpu::LoadOp::Clear(clear),
                                    store: wgpu::StoreOp::Store,
                                },
                                depth_slice: None,
                            })],
                                depth_stencil_attachment: None,
                                occlusion_query_set: None,
                                timestamp_writes: None,
                                multiview_mask: None,
                            });
                            rpass.set_pipeline(&render_pipeline);
                            rpass.set_vertex_buffer(0, vertex_buffer.slice(..));
                            rpass.draw(0..(vertices.len() as u32), 0..1);
                        }

                        queue.submit(Some(encoder.finish()));
                        frame.present();
                    }
                    _ => {}
                },
                Event::AboutToWait => {
                    window_for_redraw.request_redraw();
                }
                _ => {}
            }
        })
        .unwrap();
}
