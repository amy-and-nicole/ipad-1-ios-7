#!/bin/zsh

set -e

cd "$(dirname "$0")"
code="$PWD/resources"
deps="$PWD/dependencies"
temp="$PWD/temp"

repo_6="$deps/SundanceInH2A"
repo_legacy="$deps/Legacy-iOS-Kit"
repo_lyncis="$deps/lyncis_site"
repo_dyld="$deps/dyld"
ipsw_5_ipad="$deps/iPad1,1_5.1.1_9B206_Restore.ipsw"
ipsw_7_ipad="$deps/iPad2,1_7.1.2_11D257_Restore.ipsw"
ipsw_7_iphone="$deps/iPhone3,1_7.1.2_11D257_Restore.ipsw"
debs="$deps/debs"

root=/Volumes/Sochi11D257.K93OS
root_iphone=/Volumes/Sochi11D257.N90OS
root_5=/Volumes/Hoodoo9B206.K48OS
ramdisk=/Volumes/ramdisk

function get_deps
{
	rm -rf "$deps"
	mkdir "$deps"
	pushd "$deps"
	
	git clone 'https://github.com/NyanSatan/SundanceInH2A'
	git -C SundanceInH2A checkout 0218b8db7d89a643cd0ad28f29fbdf496b88d4e3

	git clone 'https://github.com/LukeZGD/Legacy-iOS-Kit'
	git -C Legacy-iOS-Kit checkout 26fffdfdaaa247577ecfaad4377cb6f697716bd5

	git clone 'https://github.com/staturnzz/lyncis_site'
	git -C lyncis_site checkout 49f7206119c5b66fa1b1d5d57083ecb4864ca584

	git clone 'https://github.com/apple-oss-distributions/dyld'
	git -C dyld checkout dyld-353.2.1

	curl -f 'https://secure-appldnld.apple.com/iOS5.1.1/041-4292.02120427.Tkk0d/iPad1,1_5.1.1_9B206_Restore.ipsw' -O
	curl -f 'https://secure-appldnld.apple.com/iOS7.1/031-4776.20140627.JjYSr/iPad2,1_7.1.2_11D257_Restore.ipsw' -O
	curl -f 'http://appldnld.apple.com/iOS7.1/031-4812.20140627.cq6y8/iPhone3,1_7.1.2_11D257_Restore.ipsw' -O

	mkdir debs
	
	popd
}

function eject_all()
{
	set +e
	diskutil eject "$root"
	diskutil eject "$root_iphone"
	diskutil eject "$root_5"
	diskutil eject "$ramdisk"
	set -e
}

function setup()
{
	rm -rf "$temp"
	mkdir "$temp"
	pushd "$temp"

	unzip "$ipsw_5_ipad" -d ios_5_ipad
	unzip "$ipsw_7_ipad" -d ios_7_ipad
	unzip "$ipsw_7_iphone" -d ios_7_iphone
	
	# for rootfs
	
	dmg extract ios_7_ipad/058-4388-009.dmg root.dmg -k 2ce48d3e6cbd6fd68c775f2f0261e205f27c78280035bb6bffadccfbec44f4d890bd34b9
	hdiutil resize -size 1.5g root.dmg
	hdiutil attach -owners on root.dmg
	
	# for kc and dsc
	
	dmg extract ios_7_iphone/058-4520-010.dmg root_ios_7_iphone.dmg -k 38d0320d099b9dd34ffb3308c53d397f14955b347d6a433fe173acc2ced1ae78756b3684
	hdiutil attach -owners on root_ios_7_iphone.dmg
	
	# for other boot files and drivers
	
	dmg extract ios_5_ipad/038-4291-006.dmg root_ios_5_ipad.dmg -k f7bb9fd8aa3102484ab9c847dacfd3d73f1f430acb49ed7a422226f2410acee17664c91b
	hdiutil attach -owners on root_ios_5_ipad.dmg
	
	# restore ramdisk
	
	xpwntool ios_7_ipad/058-4228-009.dmg ramdisk.dmg -iv 45edee56bb315e7319e87aaa14ee0e08 -k 52ead031c3511af2c8e82f8a1185e77aa807c33d3df0db7809e6a23c59c2b15b
	hdiutil resize -size 10m ramdisk.dmg
	hdiutil attach -owners on ramdisk.dmg
	
	cp -cR ios_5_ipad output
}

function patch_boot_files()
{
	# iboot stuff that i don't understand, from pwnerblu's script
	
	xpwntool output/Firmware/dfu/iBSS.k48ap.RELEASE.dfu iBSS.bin -iv 9c69f81db931108e8efc268de3f5d94d -k 92f1cc2ca8362740734d69386fa6dde5582e18786777e1f9772d5dd364d873fb
	xpwntool output/Firmware/dfu/iBEC.k48ap.RELEASE.dfu iBEC.bin -iv bde7b0d5cf7861479d81eb23f99d2e9e -k 1ba1f38e6a5b4841c1716c11acae9ee0fb471e50362a3b0dd8d98019f174a2f2
	set +e
	iBoot32Patcher iBSS.bin iBSS.patched --rsa
	iBoot32Patcher iBEC.bin iBEC.patched --rsa --debug -b 'rd=md0 -v amfi_get_out_of_my_way=1 pio-error=0'
	set -e
	img3maker -f iBSS.patched -o output/Firmware/dfu/iBSS.k48ap.RELEASE.dfu -t ibss
	img3maker -f iBEC.patched -o output/Firmware/dfu/iBEC.k48ap.RELEASE.dfu -t ibec
	
	# device tree diff, based on pwnerblu's with fixes
	
	cp $code/DeviceTree.k47ap.img3 output/Firmware/all_flash/all_flash.k48ap.production/DeviceTree.k48ap.img3

	# Yes, I am absolutely aware that k49ap isn't actually for hardware, but it's for custom rdtr only - pwnerblu
	cp $code/DeviceTree.k48ap.img3 output/Firmware/all_flash/all_flash.k48ap.production/DeviceTree.k49ap.img3
	# iphone kc (ipad kc doesn't even start to boot the ramdisk? idk why)
	
	cp ios_7_iphone/kernelcache.release.n90 output/kernelcache.release.k48

	# custom buildmanifest
	cp $code/BuildManifest.plist output/BuildManifest.plist
}

function patch_root
{
	arg_hactivate=$1
	
	# drivers from pwnerblu's script
	
	sudo cp -a "$root_5/usr/share/firmware/multitouch/iPad.mtprops" "$root/usr/share/firmware/multitouch"
	
	sudo cp -a "$root_5/usr/share/firmware/wifi/4329b1/duo.bin" "$root/usr/share/firmware/wifi/4329c0/uno.bin"
	sudo cp -a "$root_5/usr/share/firmware/wifi/4329b1/duo.txt" "$root/usr/share/firmware/wifi/4329c0/uno.txt"
	
	# bluetooth firmware (from nyansatan, offsets via "10B329_9B206.json")
	
	sudo mkdir "$root/private/etc/bluetool"
	sudo cp "$repo_6/resources/832639820b5d5d92a684bdc15a9725c3e29cc13c."* "$root/private/etc/bluetool"
	sudo dd if="$root_5/usr/sbin/BlueTool" of="$root/private/etc/bluetool/BCM4329B1_002.002.023.0965.0971_X17_USI_090611.hcd" bs=1 skip=121632 count=16811
	
	# fixes backboardd crashes when the ipad isn't upside down??
	
	sudo rm -r "$root/System/Library/HIDPlugins/CompassPlugIn.plugin"
	
	# TODO: cc workaround, still don't understand root cause, see UIScreenEdgePanRecognizer._useGrapeFlags?
	
	cp "$root/System/Library/Caches/com.apple.dyld/dyld_shared_cache_armv7" dyld_shared_cache_armv7.patched
	
	echo -n '\x00' | dd conv=notrunc bs=1 seek=64288286 of=dyld_shared_cache_armv7.patched
	
	# re-sign dsc (boots without it, but intermittent codesigning crashes)
	
	PYTHONPATH="$repo_6" python3 -c 'from yolosign import off2page, yolosign
yolosign("dyld_shared_cache_armv7.patched", [off2page(64288286)])'
	
	sudo cp dyld_shared_cache_armv7.patched "$root/System/Library/Caches/com.apple.dyld/dyld_shared_cache_armv7"
	sudo chown -R root:wheel "$root/System/Library/Caches/com.apple.dyld"
	sudo chmod -R 755 "$root/System/Library/Caches/com.apple.dyld"
	
	# iphone dsc graphics drivers
	
	clang -fmodules -I "$repo_dyld" "$code/dsc.m" -o dsc
	
	./dsc "$root_iphone/System/Library/Caches/com.apple.dyld/dyld_shared_cache_armv7" /System/Library/Extensions/IMGSGX535GLDriver.bundle/IMGSGX535GLDriver
	codesign -fs - IMGSGX535GLDriver
	sudo mkdir "$root/System/Library/Extensions/IMGSGX535GLDriver.bundle"
	sudo cp IMGSGX535GLDriver "$root/System/Library/Extensions/IMGSGX535GLDriver.bundle"

	./dsc "$root_iphone/System/Library/Caches/com.apple.dyld/dyld_shared_cache_armv7" /System/Library/VideoDecoders/H264H2.videodecoder
	codesign -fs - H264H2.videodecoder
	sudo cp H264H2.videodecoder "$root/System/Library/VideoDecoders"

	./dsc "$root_iphone/System/Library/Caches/com.apple.dyld/dyld_shared_cache_armv7" /System/Library/VideoDecoders/MP4VH2.videodecoder
	codesign -fs - MP4VH2.videodecoder
	sudo cp MP4VH2.videodecoder "$root/System/Library/VideoDecoders"
	
	# bluetooth and hactivation
	# TODO: should probably grab a new clean gestalt plist just to be sure
	
	cp "$code/gestalt.plist" gestalt.plist
	PlistBuddy gestalt.plist -c 'add CacheExtra:XSLlJd/8sMyXO0qtvvUTBQ bool true'
	
	if [[ $arg_hactivate ]]
	then
		PlistBuddy gestalt.plist -c 'add CacheExtra:a6vjPkzcRjrsXmniFsm0dg bool true'
	fi
	
	sudo cp gestalt.plist "$root/private/var/mobile/Library/Caches/com.apple.MobileGestalt.plist"
}

function patch_jailbreak
{
	base64 -D < "$repo_lyncis/resources/jailbreak/bootstrap.tar.b64" | sudo tar xf - -C "$root"
	
	# TODO: badly messed this up to work around problems i don't understand
	# no libmis.dylib, breaks profiled and isn't needed with nyansatan's untether
	# still want aquila for kernel patch, remount, and starting substrate
	# use dirhelper instead of CrashHousekeeping to load earlier and fix substrate not injecting early enough (broken appsync, high graphics..)
	# don't move daemons to /Library because it breaks internet (i think just mDNSResponder?) and doesn't seem necessary?
	
	base64 -D < "$repo_lyncis/resources/jailbreak/lyncis.tar.b64" | sudo tar xf - -C "$root"
	sudo rm "$root/install.sh"
	sudo rm "$root/usr/lib/libmis.dylib"
	sudo mv "$root/aquila" "$root/usr/libexec/dirhelper"
	
	# optional debs to be automatically installed
	
	sudo cp -R "$debs/" "$root/private/var/root/Media/Cydia/AutoInstall"
}

function patch_ramdisk
{
	# updated for 7.1.2 by diffing pwnerblu's with stock 7.0
	
	echo -n '\x3a\xe0' | sudo dd conv=notrunc bs=1 seek=81268 of="$ramdisk/usr/sbin/asr"
	sudo codesign -fs - "$ramdisk/usr/sbin/asr"
	
	# restore options from pwnerblu's script
	
	sudo cp "$ramdisk/usr/local/share/restore/options.k93.plist" "$ramdisk/usr/local/share/restore/options.k48.plist"
	sudo PlistBuddy "$ramdisk/usr/local/share/restore/options.k48.plist" -c 'add UpdateBaseband bool false'
	
	# nyansatan's untether
	
	sudo cp "$repo_6/rc_boot/rc.boot" "$ramdisk/private/etc"
	sudo chown root:wheel "$ramdisk/private/etc/rc.boot"
	sudo chmod 755 "$ramdisk/private/etc/rc.boot"
	sudo cp "$repo_6/exploit/exploit-k48.dmg" "$ramdisk/exploit.dmg"
}

function finalize
{
	eject_all
	
	dmg build root.dmg output/038-4291-006.dmg
	img3maker -f ramdisk.dmg -o output/038-4361-021.dmg -t rdsk
	
	pushd output
	zip -r ../output.ipsw *
	popd
}

function message
{
	echo -n "\e[35m$1\e[0m" >&2
}

function prompt_enter
{
	message "($1)"
	read
}

function prompt_yes_no
{
	message "($1 y/n)"
	read answer
	if [[ "$answer" == y || "$answer" == Y ]]
	then
		echo yes
	fi
}

function countdown
{
	for count in {$1..1}
	do
		message "\r$count..."
		sleep 1
	done
	message '\r'
}

if [[ ! -e "$deps" ]]
then
	prompt_enter 'missing dependencies, enter to re-fetch'
	
	get_deps
fi

xattr -cr "$repo_legacy/bin/macos"
PATH+=":/usr/libexec:$repo_legacy/bin/macos"

eject_all

if [[ -e "$temp/output.ipsw" && $(prompt_yes_no 'use existing ipsw?') ]]
then
	pushd "$temp"
	message 'summary: using prebuilt ipsw, jailbreak unknown, hactivate unknown\n'
else
	
	arg_jailbreak=$(prompt_yes_no 'jailbreak?')
	arg_hactivate=$(prompt_yes_no 'hactivate?')
	
	setup
	
	patch_boot_files
	patch_root $arg_hactivate
	patch_ramdisk
	
	if [[ $arg_jailbreak ]]
	then
		patch_jailbreak
	fi
	
	finalize
	
	message "summary: built ipsw, jailbreak ${arg_jailbreak:-no}, hactivate ${arg_hactivate:-no}\n"
fi

while [[ ! "$(irecovery --query | grep 'MODE: DFU')" ]]
do
	prompt_enter 'no dfu device found, enter for instructions'
	
	message 'get ready\n'
	countdown 3
	
	message 'hold home + power\n'
	countdown 10
	
	message 'release power, keep holding home only\n'
	countdown 10
done

prompt_enter 'dfu device found, enter to restore'

# TODO: exits nonzero for some reason

set +e
ipwnder32 -p
set -e

idevicerestore -e output.ipsw

message 'all done\n'
