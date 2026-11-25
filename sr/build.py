#!/usr/bin/env python3
"""Build Shadowrocket configurations and sync shared domain rules across tools.

Zero third-party dependencies (uses Python 3 standard library only).
"""

from __future__ import annotations

import argparse
import base64
import concurrent.futures
import datetime as dt
import ipaddress
import json
import re
import sys
import time
import urllib.request
from pathlib import Path
from typing import Iterable

SR_DIR = Path(__file__).resolve().parent
REPO_ROOT = SR_DIR.parent
SHARED_RULES_DIR = REPO_ROOT / "rules"
SR_RULES_DIR = SR_DIR / "rules"
TEMPLATES_DIR = SR_DIR / "templates"

USER_AGENT = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
)

ADBLOCK_URLS = (
    # easylistchina+easylist already includes easylistchina in full
    "https://easylist-downloads.adblockplus.org/easylistchina+easylist.txt",
    "https://raw.githubusercontent.com/xinggsf/Adblock-Plus-Rule/master/rule.txt",
    "https://pgl.yoyo.org/adservers/serverlist.php?hostformat=adblockplus;showintro=0",
)

GFWLIST_BASE64_URL = "https://raw.githubusercontent.com/gfwlist/gfwlist/master/gfwlist.txt"
CN_BLOCKED_DOMAINS_URL = "https://raw.githubusercontent.com/Johnshall/cn-blocked-domain/release/domains.txt"

LAN_CIDRS = (
    "192.168.0.0/16",
    "10.0.0.0/8",
    "172.16.0.0/12",
    "127.0.0.0/8",
    "100.64.0.0/10",
    "fe80::/10",
    "fc00::/7",
    "::1/128",
)

BASE_SKIP_PROXY = (
    "192.168.0.0/16",
    "10.0.0.0/8",
    "172.16.0.0/12",
    "fe80::/10",
    "fc00::/7",
    "localhost",
    "*.local",
    "*.lan",
    "*.internal",
    "e.crashlytics.com",
    "captive.apple.com",
    "sequoia.apple.com",
    "seed-sequoia.siri.apple.com",
)

BASE_BYPASS_TUN = (
    "10.0.0.0/8",
    "100.64.0.0/10",
    "127.0.0.0/8",
    "169.254.0.0/16",
    "172.16.0.0/12",
    "192.0.0.0/24",
    "192.0.2.0/24",
    "192.88.99.0/24",
    "192.168.0.0/16",
    "198.18.0.0/15",
    "198.51.100.0/24",
    "203.0.113.0/24",
    "233.252.0.0/24",
    "224.0.0.0/4",
    "255.255.255.255/32",
    "::1/128",
    "::ffff:0:0/96",
    "::ffff:0:0:0/96",
    "64:ff9b::/96",
    "64:ff9b:1::/48",
    "100::/64",
    "2001::/32",
    "2001:20::/28",
    "2001:db8::/32",
    "2002::/16",
    "3fff::/20",
    "5f00::/16",
    "fc00::/7",
    "fe80::/10",
    "ff00::/8",
)

TAILSCALE_HOME_SUBNET = "10.0.0.0/24"
TAILSCALE_CGNAT_CIDR = "100.64.0.0/10"
TAILSCALE_IPV6_CIDR = "fd7a:115c:a1e0::/48"
TAILSCALE_DOMAIN_RULES = (
    "DOMAIN-SUFFIX,ts.net,TAILSCALE",
    "DOMAIN-SUFFIX,tailscale.com,DIRECT",
    "DOMAIN-SUFFIX,tailscale.io,DIRECT",
)
TAILSCALE_CIDR_RULES = (
    f"IP-CIDR,{TAILSCALE_HOME_SUBNET},TAILSCALE,no-resolve",
    f"IP-CIDR,{TAILSCALE_CGNAT_CIDR},TAILSCALE,no-resolve",
    f"IP-CIDR6,{TAILSCALE_IPV6_CIDR},TAILSCALE,no-resolve",
)

DOMAIN_RE = re.compile(
    r"^[a-z0-9_]([a-z0-9_-]{0,61}[a-z0-9_])?"
    r"(\.[a-z0-9_]([a-z0-9_-]{0,61}[a-z0-9_])?)*\.[a-z]{2,}$"
)
KEYWORD_RE = re.compile(r"^[a-z0-9_-]{2,}$")


def read_list_file(path: Path) -> list[str]:
    """Read non-empty, non-comment lines from a rule list file."""
    entries: list[str] = []
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.split("#", 1)[0].strip().lower()
        if line:
            entries.append(line)
    return entries


def read_apple_proxy_groups(path: Path) -> tuple[list[str], list[str]]:
    """Split rules/proxy_apple.txt into ([ai] domains, [proxy] domains)."""
    ai_domains: list[str] = []
    proxy_domains: list[str] = []
    current_group = "proxy"
    for raw in path.read_text(encoding="utf-8").splitlines():
        stripped = raw.strip()
        if stripped.startswith("#"):
            lower_comment = stripped.lower()
            if "[ai]" in lower_comment:
                current_group = "ai"
            elif "[proxy]" in lower_comment:
                current_group = "proxy"
            continue
        line = raw.split("#", 1)[0].strip().lower()
        if not line:
            continue
        if current_group == "ai":
            ai_domains.append(line)
        else:
            proxy_domains.append(line)
    return ai_domains, proxy_domains


def build_tailscale_bypass_list(items: Iterable[str]) -> list[str]:
    """Adjust skip-proxy / bypass-tun items so Tailscale & home LAN traffic enters TUN."""
    home_net = ipaddress.ip_network(TAILSCALE_HOME_SUBNET)
    ts_cgnat = ipaddress.ip_network(TAILSCALE_CGNAT_CIDR)
    ula_net = ipaddress.ip_network("fc00::/7")

    result: list[str] = []
    for item in items:
        try:
            net = ipaddress.ip_network(item, strict=False)
        except ValueError:
            result.append(item)
            continue

        # Drop 100.64.0.0/10 and fc00::/7 from TUN/proxy exclusions (fc00::/7 still has
        # a fallback DIRECT rule in [Rule] after fd7a:115c:a1e0::/48 -> TAILSCALE).
        if net in (ts_cgnat, ula_net):
            continue
        if net.version == home_net.version and home_net.subnet_of(net):
            result.extend(str(sub) for sub in net.address_exclude(home_net))
            continue
        result.append(item)
    return result


def sync_singbox_files(check_only: bool = False) -> None:
    """Sync shared domain lists into sing-box JSON configs and fq.sh."""
    direct_extra = read_list_file(SHARED_RULES_DIR / "direct_cn_extra.txt")
    google_cn = read_list_file(SHARED_RULES_DIR / "proxy_google_cn.txt")
    apple_ai, apple_proxy = read_apple_proxy_groups(SHARED_RULES_DIR / "proxy_apple.txt")
    tiger_brokers = read_list_file(SHARED_RULES_DIR / "proxy_tiger_brokers.txt")

    force_proxy_dns = google_cn + apple_ai + apple_proxy + tiger_brokers

    # 1. fq/sing-box-mac-client.json
    mac_path = REPO_ROOT / "fq" / "sing-box-mac-client.json"
    mac_text = mac_path.read_text(encoding="utf-8")
    mac_data = json.loads(mac_text)

    dns_suffix_rules = [
        r for r in mac_data["dns"]["rules"]
        if "domain_suffix" in r and r.get("server") == "google-dns"
    ]
    direct_rules = [
        r for r in mac_data["route"]["rules"]
        if "domain_suffix" in r and r.get("outbound") == "direct"
    ]
    ai_rules = [
        r for r in mac_data["route"]["rules"]
        if "domain_suffix" in r and r.get("outbound") == "ai"
    ]
    proxy_rules = [
        r for r in mac_data["route"]["rules"]
        if "domain_suffix" in r and r.get("outbound") == "proxy"
    ]
    if (
        len(dns_suffix_rules) != 1
        or len(direct_rules) != 1
        or len(ai_rules) != 1
        or len(proxy_rules) != 3
    ):
        raise RuntimeError(
            f"Unexpected domain_suffix rules structure in {mac_path}: "
            f"{len(dns_suffix_rules)} dns, {len(direct_rules)} direct, "
            f"{len(ai_rules)} ai, {len(proxy_rules)} proxy"
        )
    dns_suffix_rules[0]["domain_suffix"] = force_proxy_dns
    direct_rules[0]["domain_suffix"] = direct_extra
    ai_rules[0]["domain_suffix"] = apple_ai
    proxy_rules[0]["domain_suffix"] = google_cn
    proxy_rules[1]["domain_suffix"] = apple_proxy
    proxy_rules[2]["domain_suffix"] = tiger_brokers
    new_mac_text = json.dumps(mac_data, indent=2, ensure_ascii=False) + "\n"

    # 2. fq/sing-box-server.json
    srv_path = REPO_ROOT / "fq" / "sing-box-server.json"
    srv_text = srv_path.read_text(encoding="utf-8")
    srv_data = json.loads(srv_text)
    srv_whitelist_rules = [
        r for r in srv_data["route"]["rules"]
        if "domain_suffix" in r and r.get("outbound") == "outbound-direct"
    ]
    if len(srv_whitelist_rules) != 2:
        raise RuntimeError(
            f"Unexpected domain_suffix whitelist structure in {srv_path}: "
            f"{len(srv_whitelist_rules)} rules"
        )
    srv_whitelist_rules[0]["domain_suffix"] = google_cn
    srv_whitelist_rules[1]["domain_suffix"] = tiger_brokers
    new_srv_text = json.dumps(srv_data, indent=4, ensure_ascii=False) + "\n"

    # 3. fq/fq.sh embedded server config
    fq_sh_path = REPO_ROOT / "fq" / "fq.sh"
    fq_sh_text = fq_sh_path.read_text(encoding="utf-8")

    def fmt_sh_block(domains: list[str]) -> str:
        items = ",\n".join(f'          "{d}"' for d in domains)
        return (
            "      {\n"
            '        "outbound": "outbound-direct",\n'
            '        "domain_suffix": [\n'
            f"{items}\n"
            "        ]\n"
            "      }"
        )

    replacement_blocks = (
        f"{fmt_sh_block(google_cn)},\n"
        f"{fmt_sh_block(tiger_brokers)},\n"
    )
    fq_pattern = re.compile(
        r"(?:      \{\n"
        r'        "outbound": "outbound-direct",\n'
        r'        "domain_suffix": \[\n'
        r"(?:          \"[^\"]+\",?\n)+"
        r"        \]\n"
        r"      \},\n){2}"
        r'(?=      \{\n        "action": "reject",\n        "ip_is_private": true)'
    )
    new_fq_sh_text, count = fq_pattern.subn(replacement_blocks, fq_sh_text, count=1)
    if count != 1:
        raise RuntimeError(f"Failed to locate embedded domain_suffix whitelist block in {fq_sh_path}")

    updates = (
        (mac_path, mac_text, new_mac_text),
        (srv_path, srv_text, new_srv_text),
        (fq_sh_path, fq_sh_text, new_fq_sh_text),
    )
    out_of_sync: list[Path] = []
    for path, old, new in updates:
        if old != new:
            if check_only:
                out_of_sync.append(path)
            else:
                path.write_text(new, encoding="utf-8")
                print(f"[sync] Updated {path.relative_to(REPO_ROOT)}")

    if out_of_sync:
        names = ", ".join(str(p.relative_to(REPO_ROOT)) for p in out_of_sync)
        raise RuntimeError(f"Shared domain rules out of sync in: {names}")


def fetch_url(url: str, retries: int = 4, timeout: int = 30) -> str:
    """Download UTF-8 text from URL with retry and backoff."""
    last_err: Exception | None = None
    for attempt in range(1, retries + 1):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                if resp.status != 200:
                    raise RuntimeError(f"HTTP {resp.status} for {url}")
                raw = resp.read()
                return raw.decode("utf-8", errors="replace")
        except Exception as exc:  # noqa: BLE001
            last_err = exc
            if attempt < retries:
                wait_s = 2 ** (attempt - 1)
                print(f"[warn] Fetch failed ({attempt}/{retries}) for {url}: {exc}; retrying in {wait_s}s...")
                time.sleep(wait_s)
    raise RuntimeError(f"Failed to fetch {url} after {retries} attempts: {last_err}") from last_err


def classify_entry(entry: str) -> tuple[str, str]:
    """Classify an entry as ('DOMAIN-SUFFIX', domain), ('DOMAIN-KEYWORD', kw), or ('IP-CIDR', cidr)."""
    cleaned = entry.strip().lower().lstrip(".")
    try:
        if "/" in cleaned:
            net = ipaddress.ip_network(cleaned, strict=False)
        else:
            addr = ipaddress.ip_address(cleaned)
            net = ipaddress.ip_network(f"{addr}/{addr.max_prefixlen}", strict=False)
        return ("IP-CIDR", str(net))
    except ValueError:
        pass

    if "." in cleaned:
        if DOMAIN_RE.match(cleaned):
            return ("DOMAIN-SUFFIX", cleaned)
        raise ValueError(f"Invalid domain entry: {entry!r}")

    if KEYWORD_RE.match(cleaned):
        return ("DOMAIN-KEYWORD", cleaned)

    raise ValueError(f"Unrecognized rule entry: {entry!r}")


def clean_adblock_token(raw_line: str) -> str | None:
    """Extract pure hostname or IPv4 address from an AdBlock rule line."""
    line = re.sub(r"^\|?https?://", "", raw_line)
    line = re.sub(r"^\|\|", "", line)
    line = line.lstrip(".*")
    line = line.rstrip("/*")
    if line.endswith("^"):
        line = line.rstrip("^")
    line = re.sub(r":\d{2,5}$", "", line)
    line = line.lstrip(".").lower()

    if not line or re.search(r"[/^:*?]", line):
        return None

    try:
        addr = ipaddress.ip_address(line)
        if addr.version == 4:
            return str(addr)
        return None
    except ValueError:
        pass

    if DOMAIN_RE.match(line):
        return line
    return None


def is_subdomain_or_same(domain: str, suffixes: set[str]) -> bool:
    """Return True if domain equals or is a subdomain of any domain in suffixes."""
    parts = domain.split(".")
    for i in range(len(parts) - 1):
        candidate = ".".join(parts[i:])
        if candidate in suffixes:
            return True
    return False


def prune_redundant_subdomains(domains: set[str], protected_subdomains: set[str] | None = None) -> list[str]:
    """Remove child subdomains already covered by a parent DOMAIN-SUFFIX in the same set."""
    protected = protected_subdomains or set()
    kept: list[str] = []
    for d in sorted(domains, key=lambda x: (x.count("."), x)):
        parts = d.split(".")
        has_parent = any(".".join(parts[i:]) in domains for i in range(1, len(parts) - 1))
        if has_parent and d not in protected:
            continue
        kept.append(d)
    return sorted(kept)


def parse_adblock_lists(texts: Iterable[str], ignore_domains: set[str]) -> tuple[list[str], list[str]]:
    """Parse upstream AdBlock texts into deduplicated (domains, ip_cidrs)."""
    blocked_domains: set[str] = set()
    blocked_ips: set[str] = set()
    exception_domains: set[str] = set(ignore_domains)

    for text in texts:
        for raw in text.splitlines():
            row = raw.strip()
            if not row or row.startswith("!") or row.startswith("[") or "$" in row or "##" in row or "#@#" in row or "#?#" in row:
                continue

            if row.startswith("@@"):
                token = clean_adblock_token(row[2:])
                if token and "." in token:
                    exception_domains.add(token)
                continue

            token = clean_adblock_token(row)
            if not token:
                continue

            if token[0].isdigit():
                try:
                    addr = ipaddress.ip_address(token)
                    blocked_ips.add(f"{addr}/32")
                    continue
                except ValueError:
                    pass
            blocked_domains.add(token)

    filtered_domains = {
        d for d in blocked_domains
        if not is_subdomain_or_same(d, exception_domains)
    }
    pruned_domains = prune_redundant_subdomains(filtered_domains)
    sorted_ips = sorted(blocked_ips, key=lambda c: ipaddress.ip_network(c))
    return pruned_domains, sorted_ips


def parse_gfwlist(gfw_b64: str, cn_blocked_raw: str, excludes: set[str]) -> set[str]:
    """Decode and parse GFWList + cn-blocked-domain into domain suffixes."""
    decoded = base64.b64decode(gfw_b64).decode("utf-8", errors="replace").replace("\\n", "\n")
    combined = decoded + "\n" + cn_blocked_raw

    domains: set[str] = set()
    for raw in combined.splitlines():
        row = raw.strip()
        if not row or row.startswith("!") or row.startswith("@@") or row.startswith("[AutoProxy"):
            continue

        row = re.sub(r"^\|?https?://", "", row)
        row = re.sub(r"^\|\|", "", row)
        row = row.lstrip(".*")
        row = row.rstrip("/^*")
        if "/" in row:
            row = row.split("/", 1)[0]
        row = row.lstrip(".").lower()

        if not row or row in excludes:
            continue

        if DOMAIN_RE.match(row):
            domains.add(row)

    return domains


class ParsedRuleSet:
    """Normalized collection of DOMAIN-SUFFIX, DOMAIN-KEYWORD, and IP-CIDR entries."""

    def __init__(self, entries: Iterable[str]) -> None:
        self.domains: set[str] = set()
        self.keywords: set[str] = set()
        self.cidrs: set[str] = set()
        for item in entries:
            kind, val = classify_entry(item)
            if kind == "DOMAIN-SUFFIX":
                self.domains.add(val)
            elif kind == "DOMAIN-KEYWORD":
                self.keywords.add(val)
            else:
                self.cidrs.add(val)

    def all_items(self) -> set[str]:
        return self.domains | self.keywords | self.cidrs


def check_manual_conflicts(direct: ParsedRuleSet, proxy: ParsedRuleSet, reject: ParsedRuleSet) -> None:
    """Fail fast if identical rules appear in multiple manual lists."""
    overlaps = (
        ("direct vs proxy", direct.all_items() & proxy.all_items()),
        ("direct vs reject", direct.all_items() & reject.all_items()),
        ("proxy vs reject", proxy.all_items() & reject.all_items()),
    )
    errors = [f"{label}: {sorted(items)}" for label, items in overlaps if items]
    if errors:
        raise RuntimeError("Conflicting entries across manual rule lists:\n  " + "\n  ".join(errors))


def format_merged_routing_rules(direct: ParsedRuleSet, proxy: ParsedRuleSet) -> list[str]:
    """Emit DOMAIN-SUFFIX (most specific first), DOMAIN-KEYWORD, then IP-CIDR rules."""
    lines: list[str] = []

    domain_pairs = [(d, "DIRECT") for d in direct.domains] + [(d, "PROXY") for d in proxy.domains]
    # Sort more-specific subdomains (more labels) before parent domains so overrides always win
    domain_pairs.sort(key=lambda item: (-item[0].count("."), item[0]))
    for domain, action in domain_pairs:
        lines.append(f"DOMAIN-SUFFIX,{domain},{action}")

    kw_pairs = [(k, "DIRECT") for k in direct.keywords] + [(k, "PROXY") for k in proxy.keywords]
    kw_pairs.sort(key=lambda item: item[0])
    for kw, action in kw_pairs:
        lines.append(f"DOMAIN-KEYWORD,{kw},{action}")

    cidr_pairs = [(c, "DIRECT") for c in direct.cidrs] + [(c, "PROXY") for k_or_c in [proxy.cidrs] for c in k_or_c]
    cidr_pairs.sort(key=lambda item: (ipaddress.ip_network(item[0]).version, ipaddress.ip_network(item[0])))
    for cidr, action in cidr_pairs:
        lines.append(f"IP-CIDR,{cidr},{action}")

    return lines


def format_reject_rules(reject: ParsedRuleSet) -> list[str]:
    """Emit manual REJECT rules."""
    lines = [f"DOMAIN-SUFFIX,{d},REJECT" for d in sorted(reject.domains)]
    lines.extend(f"DOMAIN-KEYWORD,{k},REJECT" for k in sorted(reject.keywords))
    sorted_cidrs = sorted(reject.cidrs, key=lambda c: (ipaddress.ip_network(c).version, ipaddress.ip_network(c)))
    lines.extend(f"IP-CIDR,{c},REJECT" for c in sorted_cidrs)
    return lines


def build_shadowrocket_confs() -> None:
    """Fetch upstream lists and generate the 6 Shadowrocket .conf files."""
    t0 = time.monotonic()

    direct_entries = (
        read_list_file(SHARED_RULES_DIR / "direct_cn_extra.txt")
        + read_list_file(SR_RULES_DIR / "direct.txt")
    )
    proxy_entries = (
        read_list_file(SHARED_RULES_DIR / "proxy_google_cn.txt")
        + read_list_file(SHARED_RULES_DIR / "proxy_apple.txt")
        + read_list_file(SHARED_RULES_DIR / "proxy_tiger_brokers.txt")
        + read_list_file(SR_RULES_DIR / "proxy.txt")
    )
    reject_entries = read_list_file(SR_RULES_DIR / "reject.txt")
    ad_ignore = set(read_list_file(SR_RULES_DIR / "ad_ignore.txt"))
    gfw_extra_entries = read_list_file(SR_RULES_DIR / "gfw_extra.txt")
    gfw_excludes = set(read_list_file(SR_RULES_DIR / "gfw_exclude.txt"))

    direct_set = ParsedRuleSet(direct_entries)
    proxy_set = ParsedRuleSet(proxy_entries)
    reject_set = ParsedRuleSet(reject_entries)
    gfw_extra_set = ParsedRuleSet(gfw_extra_entries)

    check_manual_conflicts(direct_set, proxy_set, reject_set)

    all_urls = list(ADBLOCK_URLS) + [GFWLIST_BASE64_URL, CN_BLOCKED_DOMAINS_URL]
    print(f"[fetch] Downloading {len(all_urls)} upstream rule lists in parallel...")
    with concurrent.futures.ThreadPoolExecutor(max_workers=len(all_urls)) as pool:
        future_map = {url: pool.submit(fetch_url, url) for url in all_urls}
        fetched = {url: fut.result() for url, fut in future_map.items()}

    ad_texts = [fetched[u] for u in ADBLOCK_URLS]
    ad_domains, ad_ips = parse_adblock_lists(ad_texts, ad_ignore)
    # Drop entries already covered by manual reject
    ad_domains = [d for d in ad_domains if not is_subdomain_or_same(d, reject_set.domains)]
    ad_ips = [c for c in ad_ips if c not in reject_set.cidrs]
    ad_lines = [f"DOMAIN-SUFFIX,{d},REJECT" for d in ad_domains] + [
        f"IP-CIDR,{c},REJECT" for c in ad_ips
    ]

    gfw_domains = parse_gfwlist(
        fetched[GFWLIST_BASE64_URL],
        fetched[CN_BLOCKED_DOMAINS_URL],
        gfw_excludes,
    )

    # Build black-list (GFW) proxy set: manual proxy + gfw_extra + gfw_domains (manual direct & reject win)
    gfw_proxy_set = ParsedRuleSet([])
    gfw_proxy_set.domains = (
        (proxy_set.domains | gfw_extra_set.domains | gfw_domains)
        - direct_set.domains
        - reject_set.domains
    )
    gfw_proxy_set.keywords = (proxy_set.keywords | gfw_extra_set.keywords) - direct_set.keywords - reject_set.keywords
    gfw_proxy_set.cidrs = (proxy_set.cidrs | gfw_extra_set.cidrs) - direct_set.cidrs - reject_set.cidrs

    head_tpl = (TEMPLATES_DIR / "head.conf").read_text(encoding="utf-8")
    foot_tpl = (TEMPLATES_DIR / "foot.conf").read_text(encoding="utf-8")
    build_time = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d %H:%M:%S")

    std_skip_proxy = ", ".join(BASE_SKIP_PROXY)
    std_bypass_tun = ",".join(BASE_BYPASS_TUN)
    ts_skip_proxy = ", ".join(build_tailscale_bypass_list(BASE_SKIP_PROXY))
    ts_bypass_tun = ",".join(build_tailscale_bypass_list(BASE_BYPASS_TUN))

    manual_reject_lines = format_reject_rules(reject_set)
    cnip_routing_lines = format_merged_routing_rules(direct_set, proxy_set)
    gfw_routing_lines = format_merged_routing_rules(direct_set, gfw_proxy_set)

    lan_lines = [f"IP-CIDR,{cidr},DIRECT" for cidr in LAN_CIDRS]
    ts_lan_lines = [
        f"IP-CIDR,{cidr},DIRECT"
        for cidr in LAN_CIDRS
        if cidr != TAILSCALE_CGNAT_CIDR
    ]
    cn_geo_lines = ["DOMAIN-SUFFIX,cn,DIRECT", "GEOIP,CN,DIRECT"]
    ts_domain_lines = list(TAILSCALE_DOMAIN_RULES)
    ts_cidr_lines = list(TAILSCALE_CIDR_RULES)

    variants = (
        (
            "sr_cnip_ad",
            "CN/Proxy Split + AdBlock",
            std_skip_proxy,
            std_bypass_tun,
            manual_reject_lines + ad_lines + cnip_routing_lines + cn_geo_lines + lan_lines + ["FINAL,PROXY"],
        ),
        (
            "sr_cnip",
            "CN/Proxy Split",
            std_skip_proxy,
            std_bypass_tun,
            manual_reject_lines + cnip_routing_lines + cn_geo_lines + lan_lines + ["FINAL,PROXY"],
        ),
        (
            "sr_cnip_ad_ts",
            "CN/Proxy Split + AdBlock + Tailscale",
            ts_skip_proxy,
            ts_bypass_tun,
            manual_reject_lines
            + ad_lines
            + ts_domain_lines
            + cnip_routing_lines
            + ts_cidr_lines
            + cn_geo_lines
            + ts_lan_lines
            + ["FINAL,PROXY"],
        ),
        (
            "sr_cnip_ts",
            "CN/Proxy Split + Tailscale",
            ts_skip_proxy,
            ts_bypass_tun,
            manual_reject_lines
            + ts_domain_lines
            + cnip_routing_lines
            + ts_cidr_lines
            + cn_geo_lines
            + ts_lan_lines
            + ["FINAL,PROXY"],
        ),
        (
            "sr_gfw_ad",
            "GFWList Blacklist + AdBlock",
            std_skip_proxy,
            std_bypass_tun,
            manual_reject_lines + ad_lines + gfw_routing_lines + lan_lines + ["FINAL,DIRECT"],
        ),
        (
            "sr_gfw",
            "GFWList Blacklist",
            std_skip_proxy,
            std_bypass_tun,
            manual_reject_lines + gfw_routing_lines + lan_lines + ["FINAL,DIRECT"],
        ),
    )

    for name, title, skip_proxy, bypass_tun, rule_lines in variants:
        header = (
            head_tpl.replace("{{variant_title}}", title)
            .replace("{{build_time}}", build_time)
            .replace("{{skip_proxy}}", skip_proxy)
            .replace("{{bypass_tun}}", bypass_tun)
        )
        content = header + "\n".join(rule_lines) + "\n" + foot_tpl
        out_path = SR_DIR / f"{name}.conf"
        out_path.write_text(content, encoding="utf-8")
        size_kb = out_path.stat().st_size / 1024
        print(f"[build] Generated sr/{name}.conf ({len(rule_lines):,} rules, {size_kb:,.1f} KB)")

    elapsed = time.monotonic() - t0
    print(
        f"[done] Built {len(variants)} Shadowrocket configs in {elapsed:.2f}s "
        f"(AdBlock: {len(ad_lines):,}, GFWList: {len(gfw_domains):,})"
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="Sync shared rules and build Shadowrocket configs.")
    parser.add_argument(
        "--sync-only",
        action="store_true",
        help="Only sync shared domain lists into sing-box configs and fq.sh without fetching upstream lists.",
    )
    parser.add_argument(
        "--check-sync",
        action="store_true",
        help="Verify that sing-box configs and fq.sh match shared domain lists.",
    )
    args = parser.parse_args()

    sync_singbox_files(check_only=args.check_sync)
    if not args.sync_only and not args.check_sync:
        build_shadowrocket_confs()
    return 0


if __name__ == "__main__":
    sys.exit(main())
