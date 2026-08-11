import AudioToolbox
import CoreAudio
import Foundation
import Observation

/// System output volume for the default device.
///
/// Reads and writes the *virtual main* volume rather than per-channel levels,
/// which is what the volume keys and the menu bar slider both drive — so this
/// stays in step with them instead of fighting for the same device.
///
/// Everything is listener-driven: changing the volume elsewhere updates this
/// immediately, and nothing polls when the notch is closed.
@MainActor
@Observable
final class SystemVolume {
    static let shared = SystemVolume()

    private(set) var level: Float = 0.5
    private(set) var isMuted = false
    /// Some outputs — most notably aggregate and virtual devices — expose no
    /// software volume at all, and the control has to hide rather than pretend.
    private(set) var isAvailable = false

    private var device: AudioDeviceID?
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var defaultDeviceListener: AudioObjectPropertyListenerBlock?

    private init() {
        attachToDefaultDevice()
        observeDefaultDeviceChanges()
    }

    // MARK: - Public

    func set(level newLevel: Float) {
        guard isAvailable, let device else { return }
        let clamped = min(1, max(0, newLevel))

        var value = clamped
        var address = Self.volumeAddress
        let status = AudioObjectSetPropertyData(
            device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value
        )
        guard status == noErr else {
            Log.media.error("could not set volume: \(status)")
            return
        }

        level = clamped
        // Nudging the slider off zero is an unmute in every other volume UI.
        if clamped > 0, isMuted { setMuted(false) }
    }

    func setMuted(_ muted: Bool) {
        guard let device else { return }
        var value: UInt32 = muted ? 1 : 0
        var address = Self.muteAddress
        guard AudioObjectHasProperty(device, &address) else { return }

        let status = AudioObjectSetPropertyData(
            device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value
        )
        guard status == noErr else { return }
        isMuted = muted
    }

    func toggleMute() {
        setMuted(!isMuted)
    }

    // MARK: - Device plumbing

    private static var volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    private static var muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    private static var defaultDeviceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private func attachToDefaultDevice() {
        detachFromDevice()

        guard let device = Self.defaultOutputDevice() else {
            isAvailable = false
            return
        }
        self.device = device

        var address = Self.volumeAddress
        isAvailable = AudioObjectHasProperty(device, &address)
        guard isAvailable else { return }

        refresh()

        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
        AudioObjectAddPropertyListenerBlock(device, &address, DispatchQueue.main, listener)

        var mute = Self.muteAddress
        if AudioObjectHasProperty(device, &mute) {
            AudioObjectAddPropertyListenerBlock(device, &mute, DispatchQueue.main, listener)
        }
        deviceListener = listener
    }

    private func detachFromDevice() {
        guard let device, let listener = deviceListener else {
            deviceListener = nil
            return
        }
        var address = Self.volumeAddress
        AudioObjectRemovePropertyListenerBlock(device, &address, DispatchQueue.main, listener)
        var mute = Self.muteAddress
        AudioObjectRemovePropertyListenerBlock(device, &mute, DispatchQueue.main, listener)
        deviceListener = nil
    }

    /// Switching headphones or an external display re-points the default
    /// device, and the old one's volume is no longer what anyone hears.
    private func observeDefaultDeviceChanges() {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.attachToDefaultDevice() }
        }
        var address = Self.defaultDeviceAddress
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, listener
        )
        defaultDeviceListener = listener
    }

    private func refresh() {
        guard let device else { return }

        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        var address = Self.volumeAddress
        if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr {
            level = min(1, max(0, value))
        }

        var muted: UInt32 = 0
        var muteSize = UInt32(MemoryLayout<UInt32>.size)
        var mute = Self.muteAddress
        if AudioObjectHasProperty(device, &mute),
           AudioObjectGetPropertyData(device, &mute, 0, nil, &muteSize, &muted) == noErr {
            isMuted = muted != 0
        }
    }

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = defaultDeviceAddress

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        return status == noErr && deviceID != kAudioObjectUnknown ? deviceID : nil
    }
}
