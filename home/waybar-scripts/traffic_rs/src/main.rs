use pnet::datalink::{self, Channel::Ethernet};
use pnet::packet::ethernet::{EthernetPacket, EtherTypes};
use pnet::packet::ipv4::Ipv4Packet;
use pnet::packet::ipv6::Ipv6Packet;
use pnet::packet::ip::IpNextHeaderProtocols;
use pnet::packet::Packet;
use pnet::packet::tcp::TcpPacket;
use pnet::packet::udp::UdpPacket;
use std::collections::HashSet;
use std::thread;
use std::time::{Duration, Instant};
use std::fs::{File, OpenOptions};
use std::io::{BufRead, BufReader, Write};
use crossbeam_channel::{bounded, Receiver};
use serde::Serialize;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};
use std::collections::HashMap;

const CHAR_HEIGHT: usize = 32;
const PIXEL_ROWS: usize = CHAR_HEIGHT * 4; 
const FRAMERATE: u64 = 60; 
const TICK_MS: u64 = 1000 / FRAMERATE;

const FAST_UDP_WINDOW_MS: u128 = 150;
const FAST_UDP_MAX_LEN: u16 = 192;
const UDP_FAST_PORTS: &[u16] = &[53, 5353, 443, 3478, 5349, 1900];

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

#[derive(Serialize)]
struct WaybarOutput {
    text: String,
    tooltip: String,
    class: String,
}

// 3 Lanes (TCP-family, UDP-family, ICMP/Other), each has 2 sub-pixels (In, Out)
struct Lane {
    pixels: Vec<[Option<Proto>; 2]>, // [In, Out]
}

impl Lane {
    fn new() -> Self {
        Lane { pixels: vec![[None; 2]; PIXEL_ROWS] }
    }
}

struct Sniffer {
    rx: Receiver<PacketEvent>,
}

impl Sniffer {
    fn new(interface: datalink::NetworkInterface) -> Result<Self, String> {
        let (tx, rx) = bounded(10000);
        let local_ipv4s: HashSet<Ipv4Addr> = interface.ips.iter()
            .filter_map(|ip| if let pnet::ipnetwork::IpNetwork::V4(v4) = ip { Some(v4.ip()) } else { None })
            .collect();
        let local_ipv6s: HashSet<Ipv6Addr> = interface.ips.iter()
            .filter_map(|ip| if let pnet::ipnetwork::IpNetwork::V6(v6) = ip { Some(v6.ip()) } else { None })
            .collect();

        let channel_result = datalink::channel(&interface, Default::default())
            .map_err(|e| e.to_string())?;

        match channel_result {
            Ethernet(_tx, mut rx_iter) => {
                thread::spawn(move || {
                    let mut udp_recent: HashMap<(IpAddr, u16, IpAddr, u16), Instant> = HashMap::with_capacity(2048);
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
                                                        if now.duration_since(*prev).as_millis() <= FAST_UDP_WINDOW_MS {
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
                                                        if now.duration_since(*prev).as_millis() <= FAST_UDP_WINDOW_MS {
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

                                    let _ = tx.send(PacketEvent { proto, direction, fast });
                                }
                            },
                            Err(_) => { break; } 
                        }
                    }
                });
                Ok(Sniffer { rx })
            },
            _ => Err("Unhandled channel type".to_string()),
        }
    }
}

fn log_debug(msg: &str) {
    if let Ok(mut file) = OpenOptions::new().create(true).append(true).open("$HOME/.cache/waybar-scripts/traffic_debug.log") {
        let _ = writeln!(file, "{}", msg);
    }
}

fn get_bytes(iface_name: &str) -> (u64, u64) {
    if let Ok(file) = File::open("/proc/net/dev") {
        let reader = BufReader::new(file);
        for line in reader.lines() {
            if let Ok(l) = line {
                if l.contains(iface_name) {
                    let parts: Vec<&str> = l.split_whitespace().collect();
                    if parts.len() > 9 {
                        let rx_idx = if parts[0].ends_with(':') { 1 } else { 2 };
                        let tx_idx = rx_idx + 8;
                        let rx = parts.get(rx_idx).and_then(|s| s.parse::<u64>().ok()).unwrap_or(0);
                        let tx = parts.get(tx_idx).and_then(|s| s.parse::<u64>().ok()).unwrap_or(0);
                        return (rx, tx);
                    }
                }
            }
        }
    }
    (0, 0)
}

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

fn proto_lane(proto: Proto) -> usize {
    match proto {
        Proto::Tcp | Proto::Http | Proto::Https | Proto::Ssh => 0,
        Proto::Udp | Proto::Dns | Proto::Mdns | Proto::Quic | Proto::Dhcp | Proto::Ntp | Proto::Ssdp | Proto::Stun | Proto::Turn => 1,
        Proto::Icmp | Proto::Icmpv6 | Proto::Arp | Proto::Other => 2,
    }
}

fn proto_color(proto: Proto) -> &'static str {
    match proto {
        Proto::Tcp => "#f38ba8",
        Proto::Http => "#f8c176",
        Proto::Https => "#d8b4fe",
        Proto::Ssh => "#a6e3a1",
        Proto::Udp => "#89b4fa",
        Proto::Dns => "#8ad6ff",
        Proto::Mdns => "#73d4ff",
        Proto::Quic => "#66c8ff",
        Proto::Dhcp => "#f9e2af",
        Proto::Ntp => "#c4d4ff",
        Proto::Ssdp => "#fab387",
        Proto::Stun => "#7de3c5",
        Proto::Turn => "#7ff0b3",
        Proto::Icmp => "#a6e3a1",
        Proto::Icmpv6 => "#7dd3a4",
        Proto::Arp => "#f2b8a1",
        Proto::Other => "#cdd6f4",
    }
}

fn dominant_proto(protos: &[Option<Proto>]) -> Proto {
    let mut counts = std::collections::HashMap::<Proto, usize>::new();
    for p in protos.iter().flatten() {
        *counts.entry(*p).or_insert(0) += 1;
    }
    counts
        .into_iter()
        .max_by_key(|(_, c)| *c)
        .map(|(p, _)| p)
        .unwrap_or(Proto::Other)
}

fn get_interface() -> Option<datalink::NetworkInterface> {
    let interfaces = datalink::interfaces();
    let mut best_iface = None;
    let mut max_bytes = 0;
    for iface in interfaces {
        if iface.is_loopback() || !iface.is_up() || iface.ips.is_empty() { continue; }
        let (rx, tx) = get_bytes(&iface.name);
        let total = rx + tx;
        if total > max_bytes { max_bytes = total; best_iface = Some(iface); }
    }
    best_iface
}

fn format_bytes(bytes: f64) -> String {
    let units = ["", "K", "M", "G", "T"];
    let mut b = bytes;
    let mut i = 0;
    while b >= 1024.0 && i < units.len() - 1 { b /= 1024.0; i += 1; }
    if b >= 10.0 || i == 0 { format!("{:.0}{}", b, units[i]) } else { format!("{:.1}{}", b, units[i]) }
}

fn braille_char(d1: bool, d2: bool, d3: bool, d4: bool, d5: bool, d6: bool, d7: bool, d8: bool) -> char {
    let mut mask = 0u8;
    if d1 { mask |= 0x01; } // dot 1
    if d2 { mask |= 0x08; } // dot 4
    if d3 { mask |= 0x02; } // dot 2
    if d4 { mask |= 0x10; } // dot 5
    if d5 { mask |= 0x04; } // dot 3
    if d6 { mask |= 0x20; } // dot 6
    if d7 { mask |= 0x40; } // dot 7
    if d8 { mask |= 0x80; } // dot 8
    char::from_u32(0x2800 + mask as u32).unwrap_or(' ')
}

fn main() {
    ctrlc::set_handler(move || { std::process::exit(0); }).expect("Error setting Ctrl-C handler");

    let interface = match get_interface() {
        Some(iface) => { log_debug(&format!("Selected Interface: {}", iface.name)); iface },
        None => { println!("{{\"text\":\"No IFace\"}}"); return; }
    };

    let sniffer = match Sniffer::new(interface.clone()) {
        Ok(s) => s,
        Err(e) => {
            log_debug(&format!("Sniffer Error: {}", e));
            println!("{{\"text\":\"NEEDS SUDO\"}}");
            loop { thread::sleep(Duration::from_secs(60)); }
        }
    };

    // 3 Lanes: 0=TCP, 1=UDP, 2=ICMP/Other
    let mut lanes = vec![Lane::new(), Lane::new(), Lane::new()];
    let mut output_buf = String::with_capacity(CHAR_HEIGHT * 120); 
    
    let mut last_bytes_time = Instant::now();
    let (mut last_rx, mut last_tx) = get_bytes(&interface.name);
    let mut speed_str_cache = String::new();
    let mut frame_count = 0;
    let mut pps_count: u64 = 0;
    let mut pps_last = Instant::now();
    let mut pps_str = String::from("pps: 0");

    loop {
        let start = Instant::now();
        
        // 1. Shift All Lanes
        for lane in &mut lanes {
            for r in (1..PIXEL_ROWS).rev() {
                lane.pixels[r] = lane.pixels[r-1];
            }
            lane.pixels[0] = [None; 2];
        }

        // 2. Process Packets
        // We accumulate activity flags for the Top Row of each lane
        // Lane 0: TCP, Lane 1: UDP, Lane 2: ICMP/Other
        while let Ok(pkt) = sniffer.rx.try_recv() {
            let lane_idx = proto_lane(pkt.proto);
            
            match pkt.direction {
                Direction::In => lanes[lane_idx].pixels[0][0] = Some(pkt.proto),
                Direction::Out => lanes[lane_idx].pixels[0][1] = Some(pkt.proto),
                Direction::None => {
                    lanes[lane_idx].pixels[0][0] = Some(pkt.proto);
                    lanes[lane_idx].pixels[0][1] = Some(pkt.proto);
                }
            }
            if pkt.fast && PIXEL_ROWS > 1 {
                lanes[lane_idx].pixels[1][0] = Some(pkt.proto);
                lanes[lane_idx].pixels[1][1] = Some(pkt.proto);
            }
            pps_count += 1;
        }
        if pps_last.elapsed().as_millis() >= 1000 {
            pps_str = format!("pps: {}", pps_count);
            pps_count = 0;
            pps_last = Instant::now();
        }
        
        // 3. Render
        output_buf.clear();
        for c_row in 0..CHAR_HEIGHT {
            let p_y = c_row * 4;
            
            // Render each lane side-by-side
            // TCP (Red)
            let l0 = [
                lanes[0].pixels[p_y][0], lanes[0].pixels[p_y][1],
                lanes[0].pixels[p_y+1][0], lanes[0].pixels[p_y+1][1],
                lanes[0].pixels[p_y+2][0], lanes[0].pixels[p_y+2][1],
                lanes[0].pixels[p_y+3][0], lanes[0].pixels[p_y+3][1],
            ];
            let ch0 = braille_char(
                l0[0].is_some(), l0[1].is_some(), l0[2].is_some(), l0[3].is_some(),
                l0[4].is_some(), l0[5].is_some(), l0[6].is_some(), l0[7].is_some(),
            );
            let c0 = proto_color(dominant_proto(&l0));
            
            // UDP (Blue)
            let l1 = [
                lanes[1].pixels[p_y][0], lanes[1].pixels[p_y][1],
                lanes[1].pixels[p_y+1][0], lanes[1].pixels[p_y+1][1],
                lanes[1].pixels[p_y+2][0], lanes[1].pixels[p_y+2][1],
                lanes[1].pixels[p_y+3][0], lanes[1].pixels[p_y+3][1],
            ];
            let ch1 = braille_char(
                l1[0].is_some(), l1[1].is_some(), l1[2].is_some(), l1[3].is_some(),
                l1[4].is_some(), l1[5].is_some(), l1[6].is_some(), l1[7].is_some(),
            );
            let c1 = proto_color(dominant_proto(&l1));
            
            // ICMP (Green)
            let l2 = [
                lanes[2].pixels[p_y][0], lanes[2].pixels[p_y][1],
                lanes[2].pixels[p_y+1][0], lanes[2].pixels[p_y+1][1],
                lanes[2].pixels[p_y+2][0], lanes[2].pixels[p_y+2][1],
                lanes[2].pixels[p_y+3][0], lanes[2].pixels[p_y+3][1],
            ];
            let ch2 = braille_char(
                l2[0].is_some(), l2[1].is_some(), l2[2].is_some(), l2[3].is_some(),
                l2[4].is_some(), l2[5].is_some(), l2[6].is_some(), l2[7].is_some(),
            );
            let c2 = proto_color(dominant_proto(&l2));
            
            // Format line: [TCP] [UDP] [ICMP]
            // Use idle dot for empty
            let s0 = if ch0 == ' ' { format!("<span size='small' color='#313244'>·</span>") } else { format!("<span size='small' color='{}'>{}</span>", c0, ch0) };
            let s1 = if ch1 == ' ' { format!("<span size='small' color='#313244'>·</span>") } else { format!("<span size='small' color='{}'>{}</span>", c1, ch1) };
            let s2 = if ch2 == ' ' { format!("<span size='small' color='#313244'>·</span>") } else { format!("<span size='small' color='{}'>{}</span>", c2, ch2) };
            
            output_buf.push_str(&format!("{}{}{}\n", s0, s1, s2));
        }
        
        if output_buf.ends_with('\n') { output_buf.pop(); }

        // Speed Text
        frame_count += 1;
        if frame_count >= 30 {
            frame_count = 0;
            let now = Instant::now();
            let dt = now.duration_since(last_bytes_time).as_secs_f64();
            let (curr_rx, curr_tx) = get_bytes(&interface.name);
            let (mut rx_s, mut tx_s) = (0.0, 0.0);
            if dt > 0.0 {
                if curr_rx >= last_rx { rx_s = (curr_rx - last_rx) as f64 / dt; }
                if curr_tx >= last_tx { tx_s = (curr_tx - last_tx) as f64 / dt; }
            }
            last_rx = curr_rx; last_tx = curr_tx; last_bytes_time = now;
            // Compact speed display
            speed_str_cache = format!("\n<span size='small' color='#cba6f7'>⬇{}</span>\n<span size='small' color='#fab387'>⬆{}</span>", format_bytes(rx_s), format_bytes(tx_s));
        }
        output_buf.push_str(&speed_str_cache);
        output_buf.push_str(&format!("\n\n<span size='small' color='#a6adc8'>{}</span>", pps_str));

        let output = WaybarOutput {
            text: output_buf.clone(),
            tooltip: format!("Interface: {}", interface.name),
            class: "traffic-rain".to_string(),
        };

        if let Ok(json) = serde_json::to_string(&output) {
            use std::io::Write;
            let mut out = std::io::stdout().lock();
            if let Err(e) = writeln!(out, "{}", json) {
                if e.kind() == std::io::ErrorKind::BrokenPipe {
                    break;
                }
            }
        }

        let elapsed = start.elapsed();
        if elapsed.as_millis() < TICK_MS as u128 {
            thread::sleep(Duration::from_millis(TICK_MS - elapsed.as_millis() as u64));
        }
    }
}

fn print_error(msg: &str) {
    let output = WaybarOutput { text: format!("{}\n", msg), tooltip: "Error".to_string(), class: "error".to_string() };
    if let Ok(json) = serde_json::to_string(&output) {
        use std::io::Write;
        let _ = writeln!(std::io::stdout().lock(), "{}", json);
    }
}
