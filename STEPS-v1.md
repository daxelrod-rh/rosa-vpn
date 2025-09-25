# ROSA ↔ AWS VGW IPsec (Libreswan, cert-auth) — Runbook

This doc captures the full end-to-end steps we used to bring up a dual-tunnel, certificate-authenticated VPN from a ROSA/ROSA-Virt cluster to an AWS VGW, with a CUDN segment bridged via a CentOS VM running Libreswan.

## 0. Pre-VPN on the Cluster

```bash
oc apply -f yaml/service.yml
oc describe service ipsec -n vpn-infra
# Look for LoadBalancer Ingress and resolve it:
nslookup <ingress-hostname>
# Put the resolved IP into the VPN part of Terraform (CGW/NLB bits)

oc apply -f yaml/1-virt-operator.yaml
oc apply -f yaml/2-virt-hyperconverged.yaml
oc apply -f yaml/cudn.yaml
```

Create VM ipsec in namespace vpn-infra:

- **OS:** CentOS Stream 10

Add NIC:
- **Name:** cudn
- **Network:** vm-network

## 1. Configure the ipsec VM

Install pkgs + CUDN NIC:

```bash
sudo yum install -y libreswan idm-pki-tools
nmcli con add type ethernet ifname enp2s0 con-name cudn ipv4.addresses 192.168.1.10/24 ipv4.method manual autoconnect yes
nmcli con mod cudn 802-3-ethernet.mtu 1400
nmcli con up cudn
```

Enable forwarding & loose RPF:

```bash
# Forwarding (runtime + persist)
sudo sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward=1" | sudo tee /etc/sysctl.d/91-ip-forward.conf >/dev/null
sudo sysctl -p /etc/sysctl.d/91-ip-forward.conf

# Loose RPF (runtime + persist)
sudo sysctl -w net.ipv4.conf.all.rp_filter=2
sudo sysctl -w net.ipv4.conf.default.rp_filter=2
sudo sysctl -w net.ipv4.conf.enp1s0.rp_filter=2   # AWS-side NIC
sudo sysctl -w net.ipv4.conf.enp2s0.rp_filter=2   # CUDN NIC
echo -e "net.ipv4.conf.all.rp_filter=2\nnet.ipv4.conf.default.rp_filter=2\nnet.ipv4.conf.enp1s0.rp_filter=2\nnet.ipv4.conf.enp2s0.rp_filter=2" | sudo tee /etc/sysctl.d/90-multihome.conf >/dev/null
sudo sysctl -p /etc/sysctl.d/90-multihome.conf
```

## 2. AWS: Create Cert-Based VPN

**ACM PCA**

- Root CA: RSA-2048, General Purpose, no revocation.
- Subordinate CA: RSA-2048, path length 0, validity 13 months.
- Issue cert: CN/SAN vpn.daxelrod.mobb.ninja (RSA-2048) from the subordinate.

**Customer Gateway (CGW)**

Certificate-based (select the ACM cert). No IP address.

**VGW**

Create and attach to the ROSA VPC.

**S2S VPN on VGW**

- Local IPv4 CIDR: 192.168.1.0/24 (CUDN)
- Remote IPv4 CIDR: 10.10.0.0/16 (VPC)

**Note:** If using a CGW with public-IP auth (non-cert), ensure it matches the cluster's egress IP:
```bash
curl -s https://checkip.amazonaws.com | tr -d '\r'  # run from the cluster
```

## 3. Import Certs/Keys into Libreswan NSS

```bash
CRT=/home/centos/vpn.daxelrod.mobb.ninja.pem            # leaf cert (public)
KEY=/home/centos/vpn.daxelrod.mobb.ninja.key            # matching private key
CHAIN=/home/centos/subordinate.daxelrod.mobb.ninja      # intermediate PEM
P12=/root/daxelrod-v7.p12
NSSDIR=sql:/var/lib/ipsec/nss
NICK="daxelrod-v7-cert"

# Import CA chain
cd /var/lib/ipsec/nss
sudo PKICertImport -d . -n "daxelrod.mobb.ninja Root" -t "CT,C,C" -a -i /home/centos/vpn.daxelrod.mobb.ninja.root -u L
sudo PKICertImport -d . -n "subordinate.daxelrod.mobb.ninja subordinate" -t "CT,C,C" -a -i /home/centos/subordinate.daxelrod.mobb.ninja -u L

# Build PKCS#12 (you'll be prompted for an export password)
sudo openssl pkcs12 -export -in  "$CRT" -inkey "$KEY" -certfile "$CHAIN" -name "$NICK" -out "$P12"

# Import PKCS#12 into NSS (use the same password)
sudo pk12util -i "$P12" -d "$NSSDIR"

# Optional: store pin so pluto can unlock on boot
echo '<PKCS12-password>' | sudo tee /var/lib/ipsec/nss/pin.txt >/dev/null
sudo chown root:root /var/lib/ipsec/nss/pin.txt && sudo chmod 600 /var/lib/ipsec/nss/pin.txt

# Verify
sudo certutil -K -d "$NSSDIR"   # shows a key with nickname $NICK
sudo certutil -L -d "$NSSDIR"   # Root/Sub trusted; $NICK => 'u,u,u'
```

**Note:** For the sake of simplicity, we'll use the same password for the centos user on ipsec VM for all key passwords.

## 4. Libreswan Configuration (Dual Tunnels)

**/etc/ipsec.conf**

```
config setup
    uniqueids=yes
include /etc/ipsec.d/*.conf
```

**/etc/ipsec.d/aws.conf**

```
conn %default
    keyexchange=ikev2
    authby=rsasig
    type=tunnel
    left=%defaultroute
    leftcert=daxelrod-v7-cert
    leftid=%fromcert
    leftsubnet=192.168.1.0/24
    rightsubnet=10.10.0.0/16
    rightca=%same
    ike=aes128-sha1;modp2048
    esp=aes128-sha1;modp2048
    ikelifetime=28800s
    salifetime=3600s
    dpddelay=10
    retransmit-timeout=60
    auto=ignore

# Primary tunnel — this one auto-starts
conn aws-tun-1
    right=18.204.200.100
    auto=start

# Secondary/standby — bring up manually for failover
conn aws-tun-2
    right=52.20.28.136
    auto=ignore
```

Restart & bring up:

```bash
sudo ipsec addconn --checkconfig || true
sudo systemctl restart ipsec
sudo ipsec status
sudo ipsec up aws-tun-1

# Failover test later:
# sudo ipsec down aws-tun-1 && sudo ipsec up aws-tun-2
```

**Note:** Do not add a static `ip route add 10.10.0.0/16` on the ipsec host; xfrm policies handle it.

## 5. Cluster: Get NodePorts for UDP 500/4500

```bash
oc -n vpn-infra get svc ipsec -o jsonpath='{range .spec.ports[*]}{.name}:{.port}->{.nodePort}{"\n"}{end}'
```

## 6. AWS: Routes & Security

**Route tables (every RT used in the VPC):**

- Ensure a route to 192.168.1.0/24 via the VGW (propagated or explicit).
- 10.10.0.0/16 remains local.

**Security groups:**

Worker nodes' SG (the nodes backing the NLB/NodePorts):
- UDP `<nodePort-500>` from 18.204.200.100/32 and 52.20.28.136/32
- UDP `<nodePort-4500>` from the same
- From 192.168.1.0/24: ICMP, TCP 22 (opt), TCP 80 (test), NodePorts 30000–32767 you need

Target resources' SG (EC2/LBs/etc. you want to reach):
- Allow required ports from 192.168.1.0/24.

**NACLs:**
- Allow the above (or any/any as in your current setup).

## 7. CUDN Return Route (critical)

On the CUDN router/host (not on ipsec):

```bash
sudo ip route add 10.10.0.0/16 via 192.168.1.10
# make persistent per that OS
```

## 8. Quick Validation

On ipsec:

```bash
sudo ipsec status
sudo ip xfrm policy ; sudo ip xfrm state
ping -c3 -W2 -I 192.168.1.10 10.10.0.10
sudo ipsec whack --trafficstatus
```

On an EC2 in 10.10.0.0/16 whose SG allows from 192.168.1.0/24:

```bash
ping -c3 192.168.1.10
# optional
nc -vz 192.168.1.10 22
```

Failover drill:

```bash
sudo ipsec down aws-tun-1 && sudo ipsec up aws-tun-2
sudo ipsec status
```

## 9. Troubleshooting Snippets

```bash
# Remove accidental static route on ipsec host (if you added it before)
sudo ip route del 10.10.0.0/16 || true

# Normalize files, perms, SELinux labels
sudo sed -i -e 's/\r$//' /etc/ipsec.conf /etc/ipsec.secrets /etc/ipsec.d/*.conf /etc/ipsec.d/*.secrets 2>/dev/null
sudo chmod 644 /etc/ipsec.d/*.conf 2>/dev/null || true
sudo chmod 600 /etc/ipsec.secrets /etc/ipsec.d/*.secrets 2>/dev/null || true
sudo restorecon -Rv /etc/ipsec.conf /etc/ipsec.secrets /etc/ipsec.d >/dev/null

# Optional: relax RPF further while debugging
echo -e "net.ipv4.conf.all.rp_filter=0\nnet.ipv4.conf.default.rp_filter=0" | sudo tee /etc/sysctl.d/99-ipsec.conf
sudo sysctl -p /etc/sysctl.d/99-ipsec.conf

# Packet capture while probing
sudo timeout 10 sh -c "tcpdump -ni enp1s0 'udp port 4500 or esp' & ping -c3 -W2 -I 192.168.1.10 10.10.0.10 >/dev/null"
```

## 10. "Fix VPN" Notes 

- CGW must represent the cluster's NAT egress IP (if using IP-based CGW). Recreate if wrong.

Local/Remote CIDRs should be:
- **Local:** 192.168.1.0/24 (CUDN)
- **Remote:** 10.10.0.0/16 (VPC)

## 11. Optional: "other-host" in CUDN for testing (if needed)

```bash
# On the second VM in vpn-infra:
nmcli con add type ethernet ifname enp2s0 con-name cudn ipv4.addresses 192.168.1.20/24 ipv4.method manual autoconnect yes
sudo ip route add 10.10.0.0/16 via 192.168.1.10
```