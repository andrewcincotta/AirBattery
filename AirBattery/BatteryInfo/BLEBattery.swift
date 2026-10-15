//
//  AirpodsBattery.swift
//  AirBattery
//
//  Created by apple on 2024/2/9.
//
//  =================================================
//  AirPods Pro/Beats BLE 常规广播数据包定义分析:
//  advertisementData长度 = 29bit
//  00~01: 制造商ID, 固定4c00
//  02~04: 未知
//  05~06: 设备型号ID:
//           0220 = Airpods
//           0e20 = Airpods Pro
//           0a20 = Airpods Max
//           0f20 = Airpods 2
//           1320 = Airpods 3
//           1420 = Airpods Pro 2
//           0320 = PowerBeats
//           0b20 = PowerBeats Pro
//           0c20 = Beats Solo Pro
//           1120 = Beats Studio Buds
//           1020 = Beats Flex
//           0520 = BeatsX
//           0620 = Beats Solo3
//           0920 = Beats Studio3
//           1720 = Beats Studio Pro
//           1220 = Beats Fit Pro
//           1620 = Beats Studio Buds+
//  07.1:  未知
//  07.2:  耳机取出状态:
//           5 = 两只耳机都在盒内
//           1 = 任意一只耳机被取出
//  08.1:  粗略电量(左耳):
//           0~10: x10 = 电量, f: 失联
//  08.2:  粗略电量(右耳):
//           0~10: x10 = 电量, f: 失联
//  09.1:  未知
//  09.2:  充电状态
//  10.1:  翻转指示
//  10.2:  未知
//  14:    左耳电量/充电指示
//           ff = 失联
//           <64(hex) = 未充电, 当前电量
//           >64(hex) = 在充电, 减80(hex)为当前电量
//  15:    右耳电量/充电指示
//           ff = 失联
//           <64(hex) = 未充电, 当前电量
//           >64(hex) = 电量(在充电, 减80(hex)为当前电量)
//  16:    充电盒电量/充电指示
//           ff = 失联
//           <64(hex) = 未在充电
//           >64(hex) = 在充电, 减80(hex)为当前电量
//  17~19: 未知
//  20~23: 未知
//  24~28: 未知
//  =================================================
//  AirPods Pro 2 BLE 合盖广播数据包定义分析:
//  advertisementData长度 = 25bit
//  00~01: 制造商ID, 固定4c00
//  02~03: 未知
//  04:    耳机取出状态:
//           24 = 双耳都在盒外
//           26 = 仅右耳被取出
//           2c = 仅左耳被取出
//           2e = 双耳都在盒内
//  05:    未知
//  06~10: 未知
//  11:    未知
//  12:    充电盒电量/充电指示
//           失联 = ff
//           <64(hex) = 电量(未在充电)
//           >64(hex) = 电量(在充电, 减80(hex)为当前电量)
//  13:    左耳电量/充电指示
//           被取出 = ff
//           >64(hex) = 电量(在充电, 减80(hex)为当前电量)
//  14:    右耳电量/充电指示
//           被取出 = ff
//           >64(hex) = 电量(在充电, 减80(hex)为当前电量)
//  15~20: 未知
//  21~22: 未知
//  23~24: 未知
//  =================================================
import SwiftUI
import Foundation
import CoreBluetooth

class BLEBattery: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @AppStorage("ideviceOverBLE") var ideviceOverBLE = false
    //@AppStorage("cStatusOfBLE") var cStatusOfBLE = false
    @AppStorage("readBTDevice") var readBTDevice = true
    @AppStorage("readBLEDevice") var readBLEDevice = false
    @AppStorage("updateInterval") var updateInterval = 1
    @AppStorage("twsMerge") var twsMerge = 5
    
    var centralManager: CBCentralManager!
    // Peripherals with an in-flight connection attempt, keyed by identifier.
    // This also holds the strong reference CoreBluetooth requires while connecting.
    var connecting: [UUID: CBPeripheral] = [:]
    // Outstanding GATT operations (service/characteristic discovery and reads) per connection attempt.
    // The connection is closed as soon as this drops to zero.
    var pendingOps: [UUID: Int] = [:]
    // Bumped on every attempt so a stale timeout can't cancel a newer attempt.
    var attemptNumber: [UUID: Int] = [:]
    var gotBattery: Set<UUID> = []
    // Unknown peripherals that gave no battery reading (e.g. other people's devices) and when they may be retried.
    var retryAfter: [UUID: Double] = [:]
    var otherAppleDevices: [String] = []
    var bleDevicesLevel: [String:UInt8] = [:]
    var bleDevicesVendor: [String:String] = [:]
    var scanTimer: Timer?
    //var a = 1
    //var mfgData: Data!
    
    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }
    
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            // 开始扫描
            scan(longScan: true)
        } else {
            // 蓝牙不可用，停止扫描
            //stopScan()
        }
    }

    func startScan() {
        // 每隔一段时间启动一次扫描
        let interval = TimeInterval(29 * updateInterval)
        scanTimer = Timer.scheduledTimer(timeInterval: interval, target: self, selector: #selector(scan), userInfo: nil, repeats: true)
        print("ℹ️ Start scanning BLE devices...")
        // 立即启动一次扫描
        scan(longScan: true)
    }

    @objc func scan(longScan: Bool = false) {
        if centralManager.state == .poweredOn && !centralManager.isScanning {
            centralManager.scanForPeripherals(withServices: nil, options: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + (longScan ? 15.0 : 5.0)) {
                self.stopScan()
            }
        }
    }

    func stopScan() {
        centralManager.stopScan()
    }
    
    // Starts at most one connection attempt per peripheral and always ends it (on completion or timeout).
    // macOS never times out pending connections on its own, so without this, connections to devices that
    // can't be read (or have walked away) pile up in crowded places and starve new ones, e.g. your iPhone.
    func connectForBattery(_ peripheral: CBPeripheral) {
        let id = peripheral.identifier
        if connecting[id] != nil { return }
        if let until = retryAfter[id], Date().timeIntervalSince1970 < until { return }
        let attempt = (attemptNumber[id] ?? 0) + 1
        attemptNumber[id] = attempt
        connecting[id] = peripheral
        pendingOps[id] = 0
        gotBattery.remove(id)
        centralManager.connect(peripheral, options: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self = self, self.connecting[id] != nil, self.attemptNumber[id] == attempt else { return }
            self.finishConnection(peripheral)
        }
    }

    func finishConnection(_ peripheral: CBPeripheral) {
        let id = peripheral.identifier
        guard connecting[id] != nil else { return }
        // Back off unknown peripherals that connected but gave no battery level (other people's devices, lights,
        // etc.) so they aren't reconnected every scan. Plain timeouts aren't penalised; the device may just be far away.
        if peripheral.state == .connected && !gotBattery.contains(id) && AirBatteryModel.getByName(peripheral.name ?? "") == nil {
            retryAfter[id] = Date().timeIntervalSince1970 + 1800
        }
        connecting[id] = nil
        pendingOps[id] = nil
        gotBattery.remove(id)
        centralManager.cancelPeripheralConnection(peripheral)
    }

    // Adjusts the outstanding operation count and closes the connection once nothing is left to wait for.
    func trackOps(_ peripheral: CBPeripheral, _ delta: Int) {
        let id = peripheral.identifier
        guard let ops = pendingOps[id] else { return }
        pendingOps[id] = ops + delta
        if ops + delta <= 0 { finishConnection(peripheral) }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        finishConnection(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        finishConnection(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard connecting[peripheral.identifier] != nil else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.delegate = self
        trackOps(peripheral, 1)
        peripheral.discoverServices([CBUUID(string: "180F"), CBUUID(string: "180A")])
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        var get = false
        let now = Double(Date().timeIntervalSince1970)
        if let deviceName = peripheral.name{
            if AirBatteryModel.checkIfBlocked(name: deviceName) { return }
            if let data = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data, data.count > 0 {
                if data[0] != 76 {
                    //获取非Apple的普通BLE设备数据
                    if readBLEDevice {
                        if let device = AirBatteryModel.getByName(deviceName) {
                            if now - device.lastUpdate > Double(60 * updateInterval) { get = true } } else { get = true }
                    }
                } else {
                    if data.count > 2 {
                        //获取ios个人热点广播数据
                        if [16, 12].contains(data[2]) && !otherAppleDevices.contains(deviceName) && ideviceOverBLE {
                            if let device = AirBatteryModel.getByName(deviceName), let _ = device.deviceModel { if now - device.lastUpdate > Double(60 * updateInterval) { get = true } } else { get = true }
                        }
                        //获取Airpods合盖状态消息
                        if data.count == 25 && data[2] == 18 && readBTDevice { getAirpods(peripheral: peripheral, data: data, messageType: "close") }
                        //获取Airpods开盖状态消息
                        if data.count == 29 && data[2] == 7 && readBTDevice { getAirpods(peripheral: peripheral, data: data, messageType: "open") }
                    }
                }
            }
        }
        if get { connectForBattery(peripheral) }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        //guard let name = peripheral.name else { return }
        //let blockedItems = (ud.object(forKey: "blockedDevices") as? [String]) ?? [String]()
        //if blockedItems.contains(name) && !whitelistMode { return }
        //if !blockedItems.contains(name) && whitelistMode { return }
        defer { trackOps(peripheral, -1) }
        guard error == nil, let services = peripheral.services else { return }
        for service in services {
            trackOps(peripheral, 1)
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        //guard let name = peripheral.name else { return }
        //let blockedItems = (ud.object(forKey: "blockedDevices") as? [String]) ?? [String]()
        //if blockedItems.contains(name) && !whitelistMode { return }
        //if !blockedItems.contains(name) && whitelistMode { return }
        defer { trackOps(peripheral, -1) }
        guard error == nil, let characteristics = service.characteristics else { return }
        if service.uuid == CBUUID(string: "180F") || service.uuid == CBUUID(string: "180A") {
            for characteristic in characteristics {
                if characteristic.uuid == CBUUID(string: "2A19") || characteristic.uuid == CBUUID(string: "2A24") || characteristic.uuid == CBUUID(string: "2A29") {
                    trackOps(peripheral, 1)
                    peripheral.readValue(for: characteristic)
                }
            }
        }
    }
    
    //电量信息
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        //guard let name = peripheral.name else { return }
        //let blockedItems = (ud.object(forKey: "blockedDevices") as? [String]) ?? [String]()
        //if blockedItems.contains(name) && !whitelistMode { return }
        //if !blockedItems.contains(name) && whitelistMode { return }
        
        defer { trackOps(peripheral, -1) }
        // Other people's devices reject the read with "Encryption is insufficient"
        guard error == nil else { return }
        if characteristic.uuid == CBUUID(string: "2A19"){
            if let data = characteristic.value, !data.isEmpty, let deviceName = peripheral.name {
                let now = Date().timeIntervalSince1970
                let level = Int(data[0])
                if level > 100 { return }
                gotBattery.insert(peripheral.identifier)
                var charging = 0
                //if let lastLevel = bleDevicesLevel[deviceName], cStatusOfBLE {
                if let lastLevel = bleDevicesLevel[deviceName] {
                    if level > lastLevel { charging = 1 }
                    //if level < lastLevel { charging = 0 }
                }
                bleDevicesLevel[deviceName] = data[0]
                if var device = AirBatteryModel.getByName(deviceName) {
                    device.deviceID = peripheral.identifier.uuidString
                    device.batteryLevel = level
                    device.lastUpdate = now
                    if charging != -1 { device.isCharging = charging }
                    AirBatteryModel.updateDevice(device)
                } else {
                    let device = Device(deviceID: peripheral.identifier.uuidString, deviceType: getType(deviceName), deviceName: deviceName, batteryLevel: level, isCharging: charging, lastUpdate: now)
                    AirBatteryModel.updateDevice(device)
                }
            }
        }
        
        //设备型号
        if characteristic.uuid == CBUUID(string: "2A24") {
            if let data = characteristic.value, let model = data.ascii(), let deviceName = peripheral.name, let vendor = bleDevicesVendor[deviceName] {
                if vendor == "Apple Inc." && model.contains("Watch") { otherAppleDevices.append(deviceName); return }
                if var device = AirBatteryModel.getByName(deviceName), device.deviceModel != model{
                    if vendor == "Apple Inc." {
                        device.deviceType = model.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "\\d", with: "", options: .regularExpression, range: nil)
                        device.deviceModel = model
                    } else {
                        device.deviceType = getType(deviceName)
                    }
                    device.lastUpdate = Date().timeIntervalSince1970
                    AirBatteryModel.updateDevice(device)
                }
            }
        }
        
        //厂商信息
        if characteristic.uuid == CBUUID(string: "2A29") {
            if let deviceName = peripheral.name {
                //Apple = Apple Inc.
                if let data = characteristic.value, let vendor = data.ascii() { bleDevicesVendor[deviceName] = vendor }
            }
        }
        //self.centralManager.cancelPeripheralConnection(peripheral)
    }
    
    func getLevel(_ name: String, _ side: String) -> UInt8{
        //guard let result = process(path: "/usr/sbin/system_profiler", arguments: ["SPBluetoothDataType", "-json"]) else { return 255 }
        if let json = try? JSONSerialization.jsonObject(with: Data(SPBluetoothDataModel.shared.data.utf8), options: []) as? [String: Any],
        let SPBluetoothDataTypeRaw = json["SPBluetoothDataType"] as? [Any],
        let SPBluetoothDataType = SPBluetoothDataTypeRaw[0] as? [String: Any],
        let device_connected = SPBluetoothDataType["device_connected"] as? [Any] {
            for device in device_connected{
                let d = device as! [String: Any]
                if let n = d.keys.first,n == name,let info = d[n] as? [String: Any] {
                    if let level = info["device_batteryLevel"+side] as? String {
                        return UInt8(level.replacingOccurrences(of: "%", with: "")) ?? 255
                    }
                }
            }
        }
        return 255
    }
    
    func getType(_ name: String) -> String{
        //guard let result = process(path: "/usr/sbin/system_profiler", arguments: ["SPBluetoothDataType", "-json"]) else { return "general_bt" }
        if let json = try? JSONSerialization.jsonObject(with: Data(SPBluetoothDataModel.shared.data.utf8), options: []) as? [String: Any],
        let SPBluetoothDataTypeRaw = json["SPBluetoothDataType"] as? [Any],
        let SPBluetoothDataType = SPBluetoothDataTypeRaw[0] as? [String: Any],
        let device_connected = SPBluetoothDataType["device_connected"] as? [Any] {
            for device in device_connected{
                let d = device as! [String: Any]
                if let n = d.keys.first,n == name,let info = d[n] as? [String: Any] {
                    if let type = info["device_minorType"] as? String {
                        return type
                    }
                }
            }
        }
        return "general_bt"
    }
    
    func getAirpods(peripheral: CBPeripheral, data: Data, messageType: String) {
        guard let name = peripheral.name else { return }
        if AirBatteryModel.checkIfBlocked(name: name) { return }
        
        if let deviceName = peripheral.name{
            //NSLog("AirPods: \(messageType) message [\(data.hexEncodedString())]")
            let now = Date().timeIntervalSince1970
            let dataHex = data.hexEncodedString()
            let index = dataHex.index(dataHex.startIndex, offsetBy: 14)
            let flip = (strtoul(String(dataHex[index]), nil, 16) & 0x02) == 0
            let deviceID = peripheral.identifier.uuidString
            var model = (messageType == "open" ? getHeadphoneModel(String(format: "%02x%02x", data[6], data[5])) : "Airpods Pro 2")
            if let Case = AirBatteryModel.getByName(deviceName + " (Case)".local) { model = Case.deviceModel ?? model }
            
            var caseLevel = data[messageType == "open" ? 16 : 12]
            var caseCharging = 0
            if caseLevel != 255 {
                caseCharging = caseLevel > 100 ? 1 : 0
                caseLevel = (caseLevel ^ 128) & caseLevel
            }else{ caseLevel = getLevel(deviceName, "Case") }
            
            var leftLevel = data[messageType == "open" ? (flip ? 15 : 14) : 13]
            var leftCharging = 0
            if leftLevel != 255 {
                leftCharging = leftLevel > 100 ? 1 : 0
                leftLevel = (leftLevel ^ 128) & leftLevel
            }else{ leftLevel = getLevel(deviceName, "Left") }
            
            var rightLevel = data[messageType == "open" ? (flip ? 14 : 15) : 14]
            var rightCharging = 0
            if rightLevel != 255 {
                rightCharging = rightLevel > 100 ? 1 : 0
                rightLevel = (rightLevel ^ 128) & rightLevel
            }else{ rightLevel = getLevel(deviceName, "Right") }
            
            if !["Airpods Max", "Beats Solo Pro", "Beats Solo 3", "Beats Studio Pro"].contains(model) {
                if caseLevel != 255 { AirBatteryModel.updateDevice(Device(deviceID: deviceID, deviceType: "ap_case", deviceName: deviceName + " (Case)".local, deviceModel: model, batteryLevel: Int(caseLevel), isCharging: caseCharging, lastUpdate: now)) }
                
                if leftLevel != 255 && rightLevel != 255 && (abs(Int(leftLevel) - Int(rightLevel)) < twsMerge) && leftCharging == rightCharging {
                    AirBatteryModel.hideDevice(deviceName + " 🄻")
                    AirBatteryModel.hideDevice(deviceName + " 🅁")
                    AirBatteryModel.updateDevice(Device(deviceID: deviceID + "_All", deviceType: "ap_pod_all", deviceName: deviceName + " 🄻🅁", deviceModel: model, batteryLevel: Int(min(leftLevel, rightLevel)), isCharging: leftCharging, isHidden: false, parentName: deviceName + " (Case)".local, lastUpdate: now))
                } else {
                    AirBatteryModel.hideDevice(deviceName + " 🄻🅁")
                    if leftLevel != 255 { AirBatteryModel.updateDevice(Device(deviceID: deviceID + "_Left", deviceType: "ap_pod_left", deviceName: deviceName + " 🄻", deviceModel: model, batteryLevel: Int(leftLevel), isCharging: leftCharging, isHidden: false, parentName: deviceName + " (Case)".local ,lastUpdate: now)) }
                    if rightLevel != 255 { AirBatteryModel.updateDevice(Device(deviceID: deviceID + "_Right", deviceType: "ap_pod_right", deviceName: deviceName + " 🅁", deviceModel: model, batteryLevel: Int(rightLevel), isCharging: rightCharging, isHidden: false, parentName: deviceName + " (Case)".local, lastUpdate: now)) }
                }
            } else {
                if model == "Beats Studio Pro" {
                    AirBatteryModel.updateDevice(Device(deviceID: deviceID, deviceType: "ap_case", deviceName: deviceName, deviceModel: model, batteryLevel: Int(rightLevel), isCharging: rightCharging, lastUpdate: now))
                } else {
                    leftLevel = leftLevel != 255 ? leftLevel : 0
                    rightLevel = rightLevel != 255 ? rightLevel : 0
                    AirBatteryModel.updateDevice(Device(deviceID: deviceID, deviceType: "ap_case", deviceName: deviceName, deviceModel: model, batteryLevel: Int(max(rightLevel, leftLevel)), isCharging: rightCharging + leftCharging > 0 ? 1 : 0, lastUpdate: now))
                }
            }
            //print("Type: \(messageType), C:\(caseLevel), L:\(leftLevel), R:\(rightLevel), Flip:\(messageType == "open" ? "\(flip)" : "none")")
            //print("Raw Data: \(data.hexEncodedString())")
        }
    }
    
    func getPaired() -> [String]{
        var paired:[String] = []
        //guard let result = process(path: "/usr/sbin/system_profiler", arguments: ["SPBluetoothDataType", "-json"]) else { return paired }
        if let json = try? JSONSerialization.jsonObject(with: Data(SPBluetoothDataModel.shared.data.utf8), options: []) as? [String: Any],
        let SPBluetoothDataTypeRaw = json["SPBluetoothDataType"] as? [Any],
        let SPBluetoothDataType = SPBluetoothDataTypeRaw[0] as? [String: Any]{
            if let device_connected = SPBluetoothDataType["device_connected"] as? [Any]{
                for device in device_connected{
                    let d = device as! [String: Any]
                    if let key = d.keys.first { paired.append(key) }
                }
            }
            if let device_connected = SPBluetoothDataType["device_not_connected"] as? [Any]{
                for device in device_connected{
                    let d = device as! [String: Any]
                    if let key = d.keys.first { paired.append(key) }
                }
            }
        }
        return paired
    }
}
