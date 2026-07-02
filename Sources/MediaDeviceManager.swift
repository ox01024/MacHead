import Foundation
import AudioToolbox
import CoreAudio

final class MediaDeviceManager {
    static let shared = MediaDeviceManager()
    
    private var originalMuteState: Bool?
    
    private init() {}
    
    /// 获取默认输入设备 ID
    private var defaultInputDeviceID: AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &deviceID
        )
        
        guard status == noErr else {
            NSLog("MacHead: 获取默认输入设备失败: %d", status)
            return nil
        }
        return deviceID
    }
    
    /// 获取或设置麦克风的静音状态
    var isMuted: Bool {
        get {
            guard let deviceID = defaultInputDeviceID else { return false }
            
            var isMuted: UInt32 = 0
            var propertySize = UInt32(MemoryLayout<UInt32>.size)
            var propertyAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            
            let status = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &propertySize, &isMuted)
            guard status == noErr else { return false }
            return isMuted != 0
        }
        set {
            guard let deviceID = defaultInputDeviceID else { return }
            
            var muteVal: UInt32 = newValue ? 1 : 0
            var propertyAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            
            var isWritable: DarwinBoolean = false
            let checkStatus = AudioObjectIsPropertySettable(deviceID, &propertyAddress, &isWritable)
            guard checkStatus == noErr, isWritable.boolValue else {
                NSLog("MacHead: 默认输入设备的静音属性不可写")
                return
            }
            
            let status = AudioObjectSetPropertyData(
                deviceID,
                &propertyAddress,
                0,
                nil,
                UInt32(MemoryLayout<UInt32>.size),
                &muteVal
            )
            
            if status == noErr {
                NSLog("MacHead: 成功设置麦克风静音状态为: %@", String(newValue))
            } else {
                NSLog("MacHead: 设置麦克风静音状态失败: %d", status)
            }
        }
    }
    
    /// 无头模式启动时调用：静音麦克风，并缓存原始状态
    func muteBuiltInMicrophone() {
        let shouldMute = UserDefaults.standard.bool(forKey: "MuteMicrophoneInHeadlessMode")
        guard shouldMute else { return }
        
        let currentMute = isMuted
        originalMuteState = currentMute
        
        if !currentMute {
            isMuted = true
            NSLog("MacHead: 自动静音内置麦克风，并保存其先前的未静音状态")
        } else {
            NSLog("MacHead: 内置麦克风已经处于静音状态，无需重复静音")
        }
    }
    
    /// 无头模式退出时调用：恢复麦克风的原始状态
    func unmuteBuiltInMicrophone() {
        if let original = originalMuteState {
            isMuted = original
            NSLog("MacHead: 已从缓存恢复麦克风的原始静音状态: %@", String(original))
            originalMuteState = nil
        } else {
            // Fallback: if no cache, unmute it
            isMuted = false
            NSLog("MacHead: 无静音状态缓存，默认将麦克风恢复为解除静音状态")
        }
    }
}
