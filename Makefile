PWD						:= $(shell pwd)
NPROC					:= $(shell nproc)
ROOTFS_L1 				:= rootfs_l1
NET_PREFIX				:= 172.192.168
NET_MASK				:= 24
TAP_L0					:= tap0
L1_MAC					:= aa:bb:cc:cc:bb:aa
L1_IP					:= ${NET_PREFIX}.128
L1_LIBVIRT_NAME 		:= l1
BRIDGE_L1				:= br1
TAP_L1					:= tap1
L2_MAC					:= cc:bb:aa:aa:bb:cc
L2_IP					:= ${NET_PREFIX}.129
ROOTFS_L2 				:= rootfs_l2
BUSYBOX 				:= busybox-1.37.0
DROPBEAR				:= dropbear-2024.85
GDB_KERNEL_L1_PORT		:= 1235
CONSOLE_L1_PORT			:= 1234
SHARE_TAG 				:= share9p

define QEMU_OPTIONS_L1
       -cpu host \
       -smp 4 \
       -m 4G \
       -kernel ${PWD}/kernel/arch/x86_64/boot/bzImage \
       -append "rdinit=/sbin/init panic=-1 console=ttyS0 nokaslr" \
       -initrd ${PWD}/${ROOTFS_L1}.cpio \
       -netdev tap,id=net,ifname=${TAP_L0},script=no,downscript=no \
       -device virtio-net-pci,netdev=net \
       -fsdev local,id=share,path=${PWD},security_model=none \
       -device virtio-9p-pci,fsdev=share,mount_tag=${SHARE_TAG} \
       -enable-kvm \
       -nographic -no-reboot
endef #define QEMU_OPTIONS_L1

define QEMU_OPTIONS_L2
	-cpu host \
	-smp 2 \
	-m 2G \
	-L ${PWD}/qemu/pc-bios \
	-kernel ${PWD}/kernel/arch/x86_64/boot/bzImage \
	-append "rdinit=/sbin/init panic=-1 console=ttyS0 nokaslr" \
	-initrd ${PWD}/${ROOTFS_L2}.cpio \
	-netdev tap,id=net,ifname=${TAP_L1},script=no,downscript=no \
	-device virtio-net-pci,mac=${L2_MAC},netdev=net \
	-enable-kvm \
	-nographic -no-reboot
endef #define QEMU_OPTIONS_L2

.PHONY: build console_l1 debug_l1 fini_env fini_l1 gdb_kernel_l1 gdb_libvirt init_env init_l1 kernel libvirt qemu rootfs_l1 rootfs_l2 run_l2 ssh_l1 ssh_l2 submodules

init_env:
	#开启ip转发
	sudo sysctl -w net.ipv4.ip_forward=1

	#创建tap
	sudo ip tuntap add name ${TAP_L0} mode tap

	#添加子网
	sudo ip addr add ${NET_PREFIX}.1/${NET_MASK} dev ${TAP_L0}

	#启动dhcp服务
	sudo dnsmasq \
		--interface=${TAP_L0} \
		--bind-interfaces \
		--dhcp-range=${NET_PREFIX}.2,${NET_PREFIX}.254 \
		--dhcp-host=${L1_MAC},${L1_IP} \
		--dhcp-host=${L2_MAC},${L2_IP} \
		-x ${PWD}/dnsmasq.pid

	#启动tap
	sudo ip link set dev ${TAP_L0} up

	#添加NAT规则
	sudo iptables -t nat -A POSTROUTING \
		-s ${NET_PREFIX}.0/${NET_MASK} \
		-o $$(ip route show default | grep -oP 'dev \K[^\s]+') \
		-j MASQUERADE

	#添加FORWARD规则
	sudo iptables -I FORWARD \
		-i ${TAP_L0} \
		-o $$(ip route show default | grep -oP 'dev \K[^\s]+') \
		-j ACCEPT
	sudo iptables -I FORWARD \
		-i $$(ip route show default | grep -oP 'dev \K[^\s]+') \
		-o ${TAP_L0} \
		-j ACCEPT

	#启动libvirtd
	${PWD}/libvirt/build/src/libvirtd -d

	@echo -e '\033[0;32m[*]\033[0minit the environment'

fini_env:
	#结束libvirtd
	kill -s TERM $$(cat $$XDG_RUNTIME_DIR/libvirt/libvirtd.pid)

	#删除FORWARD规则
	sudo iptables -D FORWARD \
		-i $$(ip route show default | grep -oP 'dev \K[^\s]+') \
		-o ${TAP_L0} \
		-j ACCEPT
	sudo iptables -D FORWARD \
		-i ${TAP_L0} \
		-o $$(ip route show default | grep -oP 'dev \K[^\s]+') \
		-j ACCEPT

	#删除NAT规则
	sudo iptables -t nat -D POSTROUTING \
		-s ${NET_PREFIX}.0/${NET_MASK} \
		-o $$(ip route show default | grep -oP 'dev \K[^\s]+') \
		-j MASQUERADE

	#关闭tap
	sudo ip link set dev ${TAP_L0} down

	#关闭dhcp服务
	sudo kill -TERM $$(cat ${PWD}/dnsmasq.pid)

	#删除tap
	sudo ip tuntap del ${TAP_L0} mode tap

	#关闭ip转发
	sudo sysctl -w net.ipv4.ip_forward=0

	@echo -e '\033[0;32m[*]\033[0mfini the environment'

debug_l1:
	gnome-terminal \
		--title "gdb for l1 qemu" \
		-- \
		gdb \
			-ex "handle SIGUSR1 noprint" -ex "set confirm on" \
			--init-eval-command="source ${PWD}/qemu/scripts/qemu-gdb.py" \
			--args \
				${PWD}/qemu/build/qemu-system-x86_64 \
				${QEMU_OPTIONS_L1} \
				-monitor none \
				-serial telnet::${CONSOLE_L1_PORT},server,nowait \
				-gdb tcp::${GDB_KERNEL_L1_PORT} -S

	gnome-terminal \
		--title "gdb for l1 kernel" \
		-- \
		gdb \
			-ex "set confirm on" \
			--init-eval-command="add-auto-load-safe-path ${PWD}/kernel/scripts/gdb/vmlinux-gdb.py" \
			--eval-command="target remote localhost:${GDB_KERNEL_L1_PORT}" \
			${PWD}/kernel/vmlinux

init_l1:
	${PWD}/libvirt/build/tools/virsh undefine ${L1_LIBVIRT_NAME} || exit 0

	cp ${PWD}/l1.example.xml ${PWD}/l1.xml
	sed -i "s|{NAME}|${L1_LIBVIRT_NAME}|" ${PWD}/l1.xml
	sed -i "s|{KERNEL}|${PWD}/kernel/arch/x86_64/boot/bzImage|" ${PWD}/l1.xml
	sed -i "s|{INITRD}|${PWD}/${ROOTFS_L1}.cpio|" ${PWD}/l1.xml
	sed -i "s|{QEMU}|${PWD}/qemu/build/qemu-system-x86_64|" ${PWD}/l1.xml
	sed -i "s|{TAP}|${TAP_L0}|" ${PWD}/l1.xml
	sed -i "s|{SHARE_HOST}|${PWD}|" ${PWD}/l1.xml
	sed -i "s|{SHARE_TAG}|${SHARE_TAG}|" ${PWD}/l1.xml
	sed -i "s|{CONSOLE_PORT}|${CONSOLE_L1_PORT}|" ${PWD}/l1.xml
	sed -i "s|{GDB_PORT}|${GDB_KERNEL_L1_PORT}|" ${PWD}/l1.xml
	${PWD}/libvirt/build/tools/virsh define ${PWD}/l1.xml

	${PWD}/libvirt/build/tools/virsh start ${L1_LIBVIRT_NAME}

fini_l1:
	${PWD}/libvirt/build/tools/virsh destroy ${L1_LIBVIRT_NAME}

run_l2:
	${PWD}/qemu/build/qemu-system-x86_64 \
		${QEMU_OPTIONS_L2}

gdb_kernel_l1:
	gnome-terminal \
		--title "gdb for l1 kernel" \
		-- \
		gdb \
			-ex "set confirm on" \
			--init-eval-command="add-auto-load-safe-path ${PWD}/kernel/scripts/gdb/vmlinux-gdb.py" \
			--eval-command="target remote localhost:${GDB_KERNEL_L1_PORT}" \
			${PWD}/kernel/vmlinux

gdb_libvirt:
	gnome-terminal \
		--title "gdb for libvirtd" \
		-- \
		gdb \
			-ex "set confirm on" \
			-ex "set follow-fork-mode parent" \
			-p $$(cat $$XDG_RUNTIME_DIR/libvirt/libvirtd.pid)

console_l1:
	gnome-terminal \
		--title "console for l1" \
		-- \
		telnet localhost ${CONSOLE_L1_PORT}

ssh_l1:
	gnome-terminal \
		--title "ssh for l1" \
		-- \
		ssh -o "StrictHostKeyChecking no" root@${L1_IP}

ssh_l2:
	gnome-terminal \
		--title "ssh for l2" \
		-- \
		ssh -o "StrictHostKeyChecking no" root@${L2_IP}

build: kernel libvirt qemu rootfs_l1 rootfs_l2
	@echo -e '\033[0;32m[*]\033[0mbuild the mqemu environment'

kernel:
	sudo apt update && \
	sudo apt install -y \
		bc bear bison dwarves flex libelf-dev libssl-dev

	make \
		-C ${PWD}/kernel \
		defconfig

	${PWD}/kernel/scripts/config \
		--file ${PWD}/kernel/.config \
		-e CONFIG_DEBUG_INFO_DWARF5 \
		-e CONFIG_GDB_SCRIPTS \
		-e CONFIG_X86_X2APIC \
		-e CONFIG_KVM \
		-e CONFIG_$(shell lsmod | grep "^kvm_" | awk '{print $$1}') \
		-e CONFIG_TUN \
		-e CONFIG_BRIDGE

	yes "" | make \
		-C ${PWD}/kernel \
		oldconfig

	bear \
		--append \
		--output ${PWD}/compile_commands.json \
		-- make \
			-C ${PWD}/kernel \
			-j ${NPROC}

	@echo -e '\033[0;32m[*]\033[0mbuild the linux kernel'

libvirt:
	if [ ! -d ${PWD}/libvirt/build ]; then \
		sudo apt update && \
		sudo apt install -y \
			docutils gnutls-dev libjson-c-dev libxml2-dev libxml2-utils meson xsltproc; \
		\
		meson setup ${PWD}/libvirt/build ${PWD}/libvirt; \
		meson configure ${PWD}/libvirt/build -Ddriver_qemu=enabled; \
		\
	fi

	bear \
		--append \
		--output ${PWD}/compile_commands.json \
		-- ninja -C ${PWD}/libvirt/build

	@echo -e '\033[0;32m[*]\033[0mbuild the libvirt'

qemu:
	sudo apt update && \
	sudo apt install -y \
		bear libfdt-dev libglib2.0-dev libpixman-1-dev ninja-build python3-pip zlib1g-dev

	cd ${PWD}/qemu && \
	./configure \
		--target-list=x86_64-softmmu \
		--enable-debug \
		--enable-kvm \
		--enable-virtfs

	bear \
		--append \
		--output ${PWD}/compile_commands.json \
		-- make \
			-C ${PWD}/qemu \
			-j ${NPROC}

	@echo -e '\033[0;32m[*]\033[0mbuild the qemu'

rootfs_l1:
	if [ ! -d ${PWD}/${ROOTFS_L1} ]; then \
		sudo apt update && \
		sudo apt install -y \
			debootstrap; \
		\
		sudo debootstrap \
			--components=main,contrib,non-free,non-free-firmware \
			stable \
			${PWD}/${ROOTFS_L1} \
			https://mirrors.tuna.tsinghua.edu.cn/debian/; \
		\
		sudo chroot \
			${PWD}/${ROOTFS_L1} \
			/bin/bash \
				-c "apt update && apt install -y bash-completion gdb git libfdt-dev libglib2.0-dev libpixman-1-dev make openssh-server pciutils strace wget"; \
		\
		#设置网卡 \
		echo "iface enp0s3 inet manual" | sudo tee ${PWD}/${ROOTFS_L1}/etc/network/interfaces.d/enp0s3.interface; \
		echo "up ip link set dev enp0s3 up" | sudo tee -a ${PWD}/${ROOTFS_L1}/etc/network/interfaces.d/enp0s3.interface; \
		echo "down ip link set dev enp0s3 down" | sudo tee -a ${PWD}/${ROOTFS_L1}/etc/network/interfaces.d/enp0s3.interface; \
		\
		#设置tap \
		echo "iface ${TAP_L1} inet manual" | sudo tee ${PWD}/${ROOTFS_L1}/etc/network/interfaces.d/${TAP_L1}.interface; \
		echo "pre-up ip tuntap add name ${TAP_L1} mode tap" | sudo tee -a ${PWD}/${ROOTFS_L1}/etc/network/interfaces.d/${TAP_L1}.interface; \
		echo "up ip link set dev ${TAP_L1} up" | sudo tee -a ${PWD}/${ROOTFS_L1}/etc/network/interfaces.d/${TAP_L1}.interface; \
		echo "down ip link set dev ${TAP_L1} down" | sudo tee -a ${PWD}/${ROOTFS_L1}/etc/network/interfaces.d/${TAP_L1}.interface; \
		echo "post-down ip tuntap del ${TAP_L1} mode tap" | sudo tee -a ${PWD}/${ROOTFS_L1}/etc/network/interfaces.d/${TAP_L1}.interface; \
		\
		#设置bridge \
		echo "auto ${BRIDGE_L1}" | sudo tee ${PWD}/${ROOTFS_L1}/etc/network/interfaces.d/${BRIDGE_L1}.interface; \
		echo "iface ${BRIDGE_L1} inet manual" | sudo tee -a ${PWD}/${ROOTFS_L1}/etc/network/interfaces.d/${BRIDGE_L1}.interface; \
		echo "pre-up ip link add name ${BRIDGE_L1} type bridge" | sudo tee -a ${PWD}/${ROOTFS_L1}/etc/network/interfaces.d/${BRIDGE_L1}.interface; \
		echo "pre-up ip link set dev ${BRIDGE_L1} address ${L1_MAC}" | sudo tee -a ${PWD}/${ROOTFS_L1}/etc/network/interfaces.d/${BRIDGE_L1}.interface; \
		echo "up ifup enp0s3" | sudo tee -a ${PWD}/${ROOTFS_L1}/etc/network/interfaces.d/${BRIDGE_L1}.interface; \
		echo "up ip link set dev enp0s3 master ${BRIDGE_L1}" | sudo tee -a ${PWD}/${ROOTFS_L1}/etc/network/interfaces.d/${BRIDGE_L1}.interface; \
		echo "up ifup ${TAP_L1}" | sudo tee -a ${PWD}/${ROOTFS_L1}/etc/network/interfaces.d/${BRIDGE_L1}.interface; \
		echo "up ip link set dev ${TAP_L1} master ${BRIDGE_L1}" | sudo tee -a ${PWD}/${ROOTFS_L1}/etc/network/interfaces.d/${BRIDGE_L1}.interface; \
		echo "up ip link set dev ${BRIDGE_L1} up" | sudo tee -a ${PWD}/${ROOTFS_L1}/etc/network/interfaces.d/${BRIDGE_L1}.interface; \
		echo "post-up dhclient -i ${BRIDGE_L1}" | sudo tee -a ${PWD}/${ROOTFS_L1}/etc/network/interfaces.d/${BRIDGE_L1}.interface; \
		echo "pre-down dhclient -r ${BRIDGE_L1}" | sudo tee -a ${PWD}/${ROOTFS_L1}/etc/network/interfaces.d/${BRIDGE_L1}.interface; \
		echo "down ip link set dev ${BRIDGE_L1} down" | sudo tee -a ${PWD}/${ROOTFS_L1}/etc/network/interfaces.d/${BRIDGE_L1}.interface; \
		echo "down ip link set dev ${TAP_L1} nomaster" | sudo tee -a ${PWD}/${ROOTFS_L1}/etc/network/interfaces.d/${BRIDGE_L1}.interface; \
		echo "down ifdown ${TAP_L1}" | sudo tee -a ${PWD}/${ROOTFS_L1}/etc/network/interfaces.d/${BRIDGE_L1}.interface; \
		echo "down ip link set dev enp0s3 nomaster" | sudo tee -a ${PWD}/${ROOTFS_L1}/etc/network/interfaces.d/${BRIDGE_L1}.interface; \
		echo "down ifdown enp0s3" | sudo tee -a ${PWD}/${ROOTFS_L1}/etc/network/interfaces.d/${BRIDGE_L1}.interface; \
		echo "post-down ip link del ${BRIDGE_L1} type bridge" | sudo tee -a ${PWD}/${ROOTFS_L1}/etc/network/interfaces.d/${BRIDGE_L1}.interface; \
		\
		#开启ip转发 \
		sudo sed -i "s|^#net.ipv4.ip_forward=1|net.ipv4.ip_forward=1|" ${PWD}/${ROOTFS_L1}/etc/sysctl.conf; \
		\
		#设置ssh服务器 \
		sudo sed -i "s|^#PermitEmptyPasswords no|PermitEmptyPasswords yes|" ${PWD}/${ROOTFS_L1}/etc/ssh/sshd_config; \
		sudo sed -i "s|^#PermitRootLogin prohibit-password|PermitRootLogin yes|" ${PWD}/${ROOTFS_L1}/etc/ssh/sshd_config; \
		\
		#设置mqemu文件夹 \
		echo "${SHARE_TAG} /root 9p trans=virtio 0 0" | sudo tee -a ${PWD}/${ROOTFS_L1}/etc/fstab; \
		\
		#设置主机名称 \
		echo "l1" | sudo tee ${PWD}/${ROOTFS_L1}/etc/hostname; \
		\
		#设置密码 \
		sudo chroot ${PWD}/${ROOTFS_L1} /bin/bash -c "passwd -d root"; \
	fi

	cd ${PWD}/${ROOTFS_L1} && \
	sudo find . | sudo cpio -o --format=newc -F ${PWD}/${ROOTFS_L1}.cpio >/dev/null

	@echo -e '\033[0;32m[*]\033[0mbuild the l1 rootfs'

rootfs_l2:
	if [ ! -d ${PWD}/${BUSYBOX} ]; then \
		wget https://busybox.net/downloads/${BUSYBOX}.tar.bz2; \
		tar -jxvf ${PWD}/${BUSYBOX}.tar.bz2; \
		make -C ${PWD}/${BUSYBOX} defconfig; \
		sed -i 's|^# \(CONFIG_STATIC\).*$$|\1=y|' ${PWD}/${BUSYBOX}/.config; \
		make -C ${PWD}/${BUSYBOX} -j ${NPROC}; \
	fi

	if [ ! -d ${PWD}/${DROPBEAR} ]; then \
		sudo apt update && \
			sudo apt install -y autoconf; \
		wget https://dropbear.nl/mirror/releases/${DROPBEAR}.tar.bz2; \
		tar -jxvf ${PWD}/${DROPBEAR}.tar.bz2; \
		cd ${PWD}/${DROPBEAR} && \
			autoconf && \
			autoheader && \
			./configure \
				--disable-zlib --disable-harden \
				--enable-static && \
			make PROGRAMS="dropbear scp" && \
			make strip; \
	fi

	if [ ! -d ${PWD}/${ROOTFS_L2} ]; then \
		mkdir -p ${PWD}/${ROOTFS_L2}/dev/pts \
			${PWD}/${ROOTFS_L2}/etc/dropbear \
			${PWD}/${ROOTFS_L2}/etc/init.d \
			${PWD}/${ROOTFS_L2}/home/root \
			${PWD}/${ROOTFS_L2}/proc \
			${PWD}/${ROOTFS_L2}/sys \
			${PWD}/${ROOTFS_L2}/usr/share/udhcp; \
		\
		touch ${PWD}/${ROOTFS_L2}/etc/passwd \
			${PWD}/${ROOTFS_L2}/etc/group; \
		\
		make -C ${PWD}/${BUSYBOX} CONFIG_PREFIX=${PWD}/${ROOTFS_L2} install; \
		make -C ${PWD}/${DROPBEAR} install DESTDIR=${PWD}/${ROOTFS_L2}; \
		\
		#设置udhcpc \
		cp ${PWD}/${BUSYBOX}/examples/udhcp/simple.script ${PWD}/${ROOTFS_L2}/usr/share/udhcp/default.script; \
		\
		#设置inittab文件 \
		echo "::sysinit:/etc/init.d/rcS" | sudo tee ${PWD}/${ROOTFS_L2}/etc/inittab; \
		echo "ttyS0::respawn:/bin/sh" | sudo tee -a ${PWD}/${ROOTFS_L2}/etc/inittab; \
		\
		#设置初始化脚本 \
		echo "#!/bin/sh" | sudo tee ${PWD}/${ROOTFS_L2}/etc/init.d/rcS; \
		echo "mount -a" | sudo tee -a ${PWD}/${ROOTFS_L2}/etc/init.d/rcS; \
		echo "/sbin/mdev -s" | sudo tee -a ${PWD}/${ROOTFS_L2}/etc/init.d/rcS; \
		echo "/sbin/ip link set dev eth0 address ${L2_MAC}" | sudo tee -a ${PWD}/${ROOTFS_L2}/etc/init.d/rcS; \
		echo "/sbin/syslogd -K" | sudo tee -a ${PWD}/${ROOTFS_L2}/etc/init.d/rcS; \
		echo "/sbin/udhcpc -i eth0 -s /usr/share/udhcp/default.script -S" | sudo tee -a ${PWD}/${ROOTFS_L2}/etc/init.d/rcS; \
		echo "/usr/sbin/addgroup -S -g 0 root" | sudo tee -a ${PWD}/${ROOTFS_L2}/etc/init.d/rcS; \
		echo "/usr/sbin/adduser -S -u 0 -G root -s /bin/sh -D root" | sudo tee -a ${PWD}/${ROOTFS_L2}/etc/init.d/rcS; \
		echo "/usr/bin/passwd -d root" | sudo tee -a ${PWD}/${ROOTFS_L2}/etc/init.d/rcS; \
		echo "/usr/local/sbin/dropbear -BRp 22" | sudo tee -a ${PWD}/${ROOTFS_L2}/etc/init.d/rcS; \
		sudo chmod +x ${PWD}/${ROOTFS_L2}/etc/init.d/rcS; \
		\
		#设置挂载文件信息 \
		echo "devpts /dev/pts devpts defaults 0 0" | sudo tee ${PWD}/${ROOTFS_L2}/etc/fstab; \
		echo "proc /proc proc defaults 0 0" | sudo tee -a ${PWD}/${ROOTFS_L2}/etc/fstab; \
		echo "sysfs /sys sysfs defaults 0 0" | sudo tee -a ${PWD}/${ROOTFS_L2}/etc/fstab; \
	fi

	cd ${PWD}/${ROOTFS_L2} && \
	sudo find . | sudo cpio -o --format=newc -F ${PWD}/${ROOTFS_L2}.cpio >/dev/null

	@echo -e '\033[0;32m[*]\033[0mbuild the l2 rootfs'

submodules:
	git submodule \
		update \
		--init \
		--progress \
		--jobs 4
