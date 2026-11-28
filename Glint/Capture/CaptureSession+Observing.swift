import AVFoundation

extension CaptureSession {
    // MARK: Device observation

    /// Reports the exposure offset (for the meter) and the lens position (for the focus rail) as they change,
    /// throttled so a moving scene doesn't flood the main actor. Replaces the previous lens's observers.
    func observeMeterAndLens(_ d: AVCaptureDevice) {
        // Each meter reading also drives shutter/ISO priority and refreshes the auto readouts.
        let meter = Throttled(interval: 0.1, minChange: 0.05) { [emit, weak self] offset in
            emit.yield(.exposure(.offset(offset)))
            guard let self else { return }
            Task { await self.followAuto(offset: offset) }
        }
        let lens = Throttled(interval: 0.1, minChange: 0.005) { [emit] in emit.yield(.focus(.lensPosition($0))) }
        let temperature = Throttled(interval: 0.25, minChange: 50) { [weak self] kelvin in
            guard let self else { return }
            Task { await self.reportAutoWhiteBalance(kelvin) }
        }
        deviceObservations = [
            d.observe(\.exposureTargetOffset, options: [.initial, .new]) { d, _ in meter.send(d.exposureTargetOffset) },
            d.observe(\.lensPosition, options: [.initial, .new]) { d, _ in lens.send(d.lensPosition) },
            d.observe(\.deviceWhiteBalanceGains, options: [.new]) { d, _ in
                temperature.send(d.temperatureAndTintValues(for: d.deviceWhiteBalanceGains).temperature)
            },
            d.observe(\.systemPressureState, options: [.initial, .new]) { [emit, weak self] d, _ in
                emit.yield(.session(.systemPressure(SystemPressure(d.systemPressureState.level))))
                self?.enqueue { $0.updateMotionAnalysis() }  // heat pauses the motion analysis
            },
        ]
    }
}
