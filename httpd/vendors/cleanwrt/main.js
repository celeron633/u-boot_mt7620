/* SPDX-License-Identifier: GPL-2.0 */
(function () {
    'use strict';
    var words = {
        brand: ['系统恢复模式', 'System recovery'],
        firmware: ['固件升级', 'Firmware update'],
        backup: ['备份', 'Backup'],
        reboot: ['重启', 'Reboot'],
        environment: ['环境设置', 'Environment'],
        language: ['语言', 'Language'],
        theme: ['主题', 'Theme'],
        auto: ['自动', 'Auto'],
        light: ['浅色', 'Light'],
        dark: ['深色', 'Dark'],
        firmware_hint: ['请选择适配当前设备的固件。上传完成后将立即写入 Flash，并自动重启。', 'Choose firmware for this device. It will be written to flash after upload, then the device will restart.'],
        upload: ['上传并更新', 'Upload and update'],
        warnings: ['注意事项', 'Warnings'],
        no_power: ['升级过程中请勿断电或断开网络。', 'Keep power and network connected during the update.'],
        auto_restart: ['写入成功后设备会自动重启，请耐心等待。', 'The device will restart automatically after a successful update.'],
        choose_correct: ['请确认设备型号与分区布局；建议更新前先备份整片 Flash。', 'Check the device model and partition layout. Make a full flash backup before updating.'],
        loading: ['正在获取设备信息…', 'Loading device information...'],
        info_failed: ['设备信息暂不可用。', 'Device information is unavailable.'],
        model: ['型号：', 'Model: '],
        ram: ['内存：', 'RAM: '],
        flash: ['闪存：', 'Flash: '],
        limit: ['固件上限：', 'Firmware limit: '],
        more: ['更多信息', 'More information'],
        offset: ['固件起始：', 'Firmware offset: '],
        bootloader: ['引导分区：', 'Bootloader partition: '],
        backup_hint: ['下载整片 Flash 的原始二进制镜像，用于编程器恢复。', 'Download a raw image of the entire flash for SPI programmer recovery.'],
        target: ['备份目标', 'Backup target'],
        full_flash: ['整片 SPI NOR Flash', 'Entire SPI NOR flash'],
        capacity: ['文件大小', 'File size'],
        detected: ['按设备实际探测容量', 'Detected flash capacity'],
        filename: ['文件名', 'Filename'],
        download: ['下载完整备份', 'Download full backup'],
        backup_contains: ['包含 U-Boot、环境变量、出厂校准、系统固件和保留分区。', 'Includes U-Boot, environment, factory calibration, firmware and reserved partitions.'],
        backup_wait: ['备份期间请保持供电和网络连接，完整下载可能需要几分钟。', 'Keep power and network connected. A complete backup may take a few minutes.'],
        backup_check: ['请确认下载文件大小等于 Flash 容量，再用于编程器恢复。', 'Check that the downloaded file matches the flash capacity before restoring it with a programmer.'],
        backup_started: ['浏览器正在处理下载，请在下载列表查看进度，并在完成后核对文件大小。', 'Check progress in your browser downloads, then verify the file size when it finishes.'],
        reboot_hint: ['退出 Web 恢复模式并重新启动设备，不会改写 Flash。', 'Leave Web recovery and restart the device. Flash contents will be preserved.'],
        reboot_now: ['立即重启', 'Reboot now'],
        reboot_wait: ['设备重启期间网页可能暂时无法访问，请勿断电。', 'The page may be unavailable during reboot. Keep the power on.'],
        confirm_reboot: ['确定现在重启设备？', 'Reboot the device now?'],
        env_hint: ['将保存的 U-Boot 环境变量恢复为当前镜像的编译默认值。', 'Restore saved U-Boot variables to the defaults compiled into this image.'],
        env_reset: ['恢复默认环境', 'Restore default environment'],
        env_warning: ['此操作会移除自定义启动与网络设置，保存成功后需重启生效。', 'This removes custom boot and network settings. Restart after saving to apply the defaults.'],
        confirm_env: ['确定恢复全部 U-Boot 环境变量为默认值？', 'Restore all U-Boot environment variables to defaults?'],
        confirm_upload: ['即将写入固件并重启，确认继续？', 'Write this firmware to flash and restart?'],
        empty_file: ['请选择至少 10 KiB 的有效固件文件。', 'Choose a valid firmware file of at least 10 KiB.'],
        oversize: ['固件超过分区上限：', 'Firmware exceeds the partition limit: '],
        uploading: ['正在上传，请保持供电和网络连接…', 'Uploading. Keep power and network connected...'],
        not_found: ['页面不存在', 'Page not found'],
        not_found_detail: ['未找到请求的页面，请从左侧导航选择功能。', 'The requested page was not found. Choose an item from the navigation.'],
        failed: ['更新失败', 'Update failed'],
        failed_detail: ['文件大小或格式不符合要求，请确认固件与设备匹配，并检查串口日志。', 'The file size or format was rejected. Check the firmware and device match, and review the serial log.'],
        too_big: ['固件过大', 'Firmware too large'],
        too_big_detail: ['固件超过当前设备分区上限，已拒绝写入。请选择容量合适的固件。', 'The firmware exceeds the partition limit and was not written. Choose a smaller image.'],
        env_ok: ['环境已恢复', 'Environment restored'],
        env_ok_detail: ['默认环境已保存。请重启设备使设置生效，默认恢复地址为 192.168.1.1。', 'Default environment saved. Reboot to apply it. The default recovery address is 192.168.1.1.'],
        env_failed: ['环境恢复失败', 'Environment restore failed'],
        env_failed_detail: ['无法保存默认环境，请查看串口日志。', 'Could not save the default environment. Check the serial log.'],
        back: ['返回固件升级', 'Back to firmware update']
    };
    var info = null, infoFailed = false, lang = 'zh';
    function getPreference(key) {
        try { return localStorage.getItem('mt7620-' + key) || 'auto'; }
        catch (error) { return 'auto'; }
    }
    function savePreference(key, value) {
        try { localStorage.setItem('mt7620-' + key, value); } catch (error) {}
    }
    function tr(key) { return words[key] ? words[key][lang === 'zh' ? 0 : 1] : key; }
    function bytes(value) {
        return (value / 1048576).toFixed(value % 1048576 ? 2 : 0) + ' MiB';
    }
    function renderInfo() {
        var box = document.getElementById('sysinfo'), size = document.getElementById('backup-size');
        if (size && info) size.textContent = bytes(info.flash) + ' (' + info.flash + ' bytes)';
        if (!box) return;
        box.removeAttribute('data-i18n');
        box.textContent = infoFailed ? tr('info_failed') : tr('loading');
        if (!info) return;
        var main = document.createElement('div');
        main.className = 'sysinfo-main';
        main.textContent = tr('model') + info.model + '\n' + tr('ram') + bytes(info.ram) + '\n' + tr('flash') + 'SPI NOR (' + bytes(info.flash) + ')';
        var details = document.createElement('details'), summary = document.createElement('summary'), body = document.createElement('div');
        summary.textContent = tr('more');
        body.className = 'sysinfo-details-body';
        body.textContent = tr('limit') + bytes(info.firmware_limit) + '\n' + tr('offset') + '0x' + info.firmware_offset.toString(16) + '\n' + tr('bootloader') + bytes(info.bootloader);
        details.appendChild(summary);
        details.appendChild(body);
        box.textContent = '';
        box.appendChild(main);
        box.appendChild(details);
    }
    function translate() {
        var preference = document.getElementById('language').value;
        lang = preference === 'auto' ? (/^zh/i.test(navigator.language) ? 'zh' : 'en') : preference;
        document.documentElement.lang = lang === 'zh' ? 'zh-CN' : 'en';
        document.querySelectorAll('[data-i18n]').forEach(function (element) {
            element.textContent = tr(element.getAttribute('data-i18n'));
        });
        document.title = document.querySelector('h1').textContent;
        var file = document.getElementById('file');
        if (file) file.setAttribute('aria-label', tr('firmware'));
        renderInfo();
    }
    var language = document.getElementById('language'), theme = document.getElementById('theme');
    language.value = getPreference('language');
    if (!language.value) language.value = 'auto';
    language.addEventListener('change', function () { savePreference('language', language.value); translate(); });
    theme.value = getPreference('theme');
    if (!theme.value) theme.value = 'auto';
    function applyTheme() {
        if (theme.value === 'auto') document.documentElement.removeAttribute('data-theme');
        else document.documentElement.setAttribute('data-theme', theme.value);
    }
    theme.addEventListener('change', function () { savePreference('theme', theme.value); applyTheme(); });
    applyTheme();
    translate();
    if (document.getElementById('sysinfo')) {
        fetch('/sysinfo', {cache: 'no-store'}).then(function (response) {
            if (!response.ok) throw new Error('sysinfo');
            return response.json();
        }).then(function (data) { info = data; renderInfo(); }).catch(function () { infoFailed = true; renderInfo(); });
    }
    document.querySelectorAll('form[data-confirm]').forEach(function (form) {
        form.addEventListener('submit', function (event) {
            if (!window.confirm(tr(form.getAttribute('data-confirm')))) event.preventDefault();
        });
    });
    var firmware = document.getElementById('firmware-form'), file = document.getElementById('file');
    if (firmware) {
        file.addEventListener('change', function () {
            var selected = file.files[0];
            document.getElementById('file-meta').textContent = selected ? selected.name + ' · ' + bytes(selected.size) : '';
        });
        firmware.addEventListener('submit', function (event) {
            var selected = file.files[0];
            if (!selected || selected.size < 10240) {
                event.preventDefault(); window.alert(tr('empty_file')); return;
            }
            if (info && selected.size > info.firmware_limit) {
                event.preventDefault(); window.alert(tr('oversize') + bytes(info.firmware_limit)); return;
            }
            if (!window.confirm(tr('confirm_upload'))) { event.preventDefault(); return; }
            firmware.querySelector('button').disabled = true;
            document.getElementById('upload-status').setAttribute('data-i18n', 'uploading');
            document.getElementById('upload-status').textContent = tr('uploading');
        });
    }
    var download = document.getElementById('download');
    if (download) download.addEventListener('click', function () {
        document.getElementById('backup-status').setAttribute('data-i18n', 'backup_started');
        document.getElementById('backup-status').textContent = tr('backup_started');
    });
}());
