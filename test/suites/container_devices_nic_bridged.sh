test_container_devices_nic_bridged() {
  ensure_import_testimage
  ensure_has_localhost_remote "${LXD_ADDR}"

  vethHostName="veth$$"
  ctName="nt$$"
  ctMAC="0A:92:a7:0d:b7:D9"
  ipRand=$(shuf -i 0-9 -n 1)
  brName="lxdt$$"

  # Standard bridge with random subnet and a bunch of options
  lxc network create "${brName}"
  lxc network set "${brName}" dns.mode managed
  lxc network set "${brName}" dns.domain blah
  lxc network set "${brName}" ipv4.routing false
  lxc network set "${brName}" ipv6.routing false
  lxc network set "${brName}" ipv6.dhcp.stateful true
  lxc network set "${brName}" ipv4.address 192.0.2.1/24
  lxc network set "${brName}" ipv6.address 2001:db8::1/64

  # Test pre-launch profile config is applied at launch
  lxc profile copy default "${ctName}"
  lxc profile device set "${ctName}" eth0 limits.ingress 1Mbit
  lxc profile device set "${ctName}" eth0 limits.egress 2Mbit
  lxc profile device set "${ctName}" eth0 host_name "${vethHostName}"
  lxc profile device set "${ctName}" eth0 mtu "1400"
  lxc profile device set "${ctName}" eth0 hwaddr "${ctMAC}"
  lxc profile device set "${ctName}" eth0 parent "${brName}"
  lxc profile device set "${ctName}" eth0 nictype "bridged"
  lxc launch testimage "${ctName}" -p "${ctName}"

  # Check profile limits are applied on boot.
  if ! tc class show dev "${vethHostName}" | grep "1Mbit" ; then
    echo "limits.ingress invalid"
    false
  fi
  if ! tc filter show dev "${vethHostName}" egress | grep "2Mbit" ; then
    echo "limits.egress invalid"
    false
  fi

  # Check profile custom MTU is applied in container on boot.
  if ! lxc exec "${ctName}" -- grep "1400" /sys/class/net/eth0/mtu ; then
    echo "mtu invalid"
    false
  fi

  # Check profile custom MAC is applied in container on boot.
  if ! lxc exec "${ctName}" -- grep -i "${ctMAC}" /sys/class/net/eth0/address ; then
    echo "mac invalid"
    false
  fi

  # Add IP alias to container and check routes actually work.
  lxc exec "${ctName}" -- ip -4 addr add "192.0.2.1${ipRand}/32" dev eth0
  lxc exec "${ctName}" -- ip -4 route add default dev eth0
  ping -c2 -W1 "192.0.2.1${ipRand}"
  lxc exec "${ctName}" -- ip -6 addr add "2001:db8::1${ipRand}/128" dev eth0
  sleep 1 #Wait for link local gateway advert.
  ping6 -c2 -W1 "2001:db8::1${ipRand}"

  # Test hot plugging a container nic with different settings to profile with the same name.
  lxc config device add "${ctName}" eth0 nic \
    nictype=bridged \
    name=eth0 \
    parent=${brName} \
    limits.ingress=3Mbit \
    limits.egress=4Mbit \
    host_name="${vethHostName}" \
    hwaddr="${ctMAC}" \
    mtu=1401

  # Check limits are applied on hot-plug.
  if ! tc class show dev "${vethHostName}" | grep "3Mbit" ; then
    echo "limits.ingress invalid"
    false
  fi
  if ! tc filter show dev "${vethHostName}" egress | grep "4Mbit" ; then
    echo "limits.egress invalid"
    false
  fi

  # Check custom MTU is applied on hot-plug.
  if ! lxc exec "${ctName}" -- grep "1401" /sys/class/net/eth0/mtu ; then
    echo "mtu invalid"
    false
  fi

  # Check custom MAC is applied on hot-plug.
  if ! lxc exec "${ctName}" -- grep -i "${ctMAC}" /sys/class/net/eth0/address ; then
    echo "mac invalid"
    false
  fi

  # Test removing hot plugged device and check profile nic is restored.
  lxc config device remove "${ctName}" eth0

  # Check profile limits are applie on hot-removal.
  if ! tc class show dev "${vethHostName}" | grep "1Mbit" ; then
    echo "limits.ingress invalid"
    false
  fi
  if ! tc filter show dev "${vethHostName}" egress | grep "2Mbit" ; then
    echo "limits.egress invalid"
    false
  fi

  # Check profile custom MTU is applied on hot-removal.
  if ! lxc exec "${ctName}" -- grep "1400" /sys/class/net/eth0/mtu ; then
    echo "mtu invalid"
    false
  fi

  # Test hot plugging a container nic then updating it.
  lxc config device add "${ctName}" eth0 nic \
    nictype=bridged \
    name=eth0 \
    parent=${brName} \
    host_name="${vethHostName}"

  lxc config device set "${ctName}" eth0 limits.ingress 3Mbit
  lxc config device set "${ctName}" eth0 limits.egress 4Mbit
  lxc config device set "${ctName}" eth0 mtu 1402
  lxc config device set "${ctName}" eth0 hwaddr "${ctMAC}"

  # Check limits are applied on update.
  if ! tc class show dev "${vethHostName}" | grep "3Mbit" ; then
    echo "limits.ingress invalid"
    false
  fi
  if ! tc filter show dev "${vethHostName}" egress | grep "4Mbit" ; then
    echo "limits.egress invalid"
    false
  fi

  # Check custom MTU is applied update.
  if ! lxc exec "${ctName}" -- grep "1402" /sys/class/net/eth0/mtu ; then
    echo "mtu invalid"
    false
  fi

  # Check custom MAC is applied update.
  if ! lxc exec "${ctName}" -- grep -i "${ctMAC}" /sys/class/net/eth0/address ; then
    echo "mac invalid"
    false
  fi

  # Cleanup.
  lxc config device remove "${ctName}" eth0

  # Test DHCP lease clearance.
  lxc delete "${ctName}" -f
  lxc launch testimage "${ctName}" -p "${ctName}"

  # Request DHCPv4 lease with custom name (to check managed name is allocated instead).
  lxc exec "${ctName}" -- /sbin/udhcpc -i eth0 -F "${ctName}custom"

  # Check DHCPv4 lease is allocated.
  if ! grep -i "${ctMAC}" "${LXD_DIR}/networks/${brName}/dnsmasq.leases" ; then
    echo "DHCPv4 lease not allocated"
    false
  fi

  # Check DHCPv4 lease has DNS record assigned.
  if ! dig @192.0.2.1 "${ctName}.blah" | grep "${ctName}.blah.\\+0.\\+IN.\\+A.\\+192.0.2." ; then
    echo "DNS resolution of DHCP name failed"
    false
  fi

  # Delete container, check LXD releases lease.
  lxc delete "${ctName}" -f

  # Check DHCPv4 lease is released.
  if grep -i "${ctMAC}" "${LXD_DIR}/networks/${brName}/dnsmasq.leases" ; then
    echo "DHCPv4 lease not released"
    false
  fi

  # Cleanup.
  lxc network delete "${brName}"
  lxc profile delete "${ctName}"
}