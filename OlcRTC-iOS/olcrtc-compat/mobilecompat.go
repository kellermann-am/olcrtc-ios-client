// Package mobile compatibility shim: restores the flat MobileXxx API the iOS
// client expects, implemented on top of the current Runtime API (upstream master).
package mobile

import "sync"

var (
	compatOnce sync.Once
	compatRT   *Runtime
)

func compat() *Runtime {
	compatOnce.Do(func() { compatRT = New() })
	return compatRT
}

// SetProviders is a no-op; provider defaults are registered by New().
func SetProviders() {}

// SetDNS sets the DNS resolver address (host:port).
func SetDNS(dns string) { _ = compat().SetDNS(dns) }

// SetTransport selects the transport.
func SetTransport(transport string) { _ = compat().SetTransport(transport) }

// SetLivenessOptions configures liveness checks (milliseconds).
func SetLivenessOptions(intervalMillis, timeoutMillis, failures int) {
	_ = compat().SetLivenessOptions(intervalMillis, timeoutMillis, failures)
}

// SetVP8Options configures vp8channel.
func SetVP8Options(fps, batchSize int) { _ = compat().SetVP8Options(fps, batchSize) }

// SetSEIOptions configures seichannel.
func SetSEIOptions(fps, batchSize, fragmentSize, ackTimeoutMillis int) {
	_ = compat().SetSEIOptions(fps, batchSize, fragmentSize, ackTimeoutMillis)
}

// SetVideoOptions configures videochannel. bitrate and hw are accepted for API
// compatibility and currently ignored by the runtime.
func SetVideoOptions(width, height, fps int, bitrate, hw string, qrSize int, qrRecovery, codec string, tileModule, tileRS int) {
	_ = compat().SetVideoOptions(width, height, fps, qrSize, qrRecovery, codec, tileModule, tileRS)
}

// StartWithTransport applies the remaining parameters and starts the runtime.
// Returns error only; gomobile maps this to a Swift Bool (success) + NSError out-param.
func StartWithTransport(carrier, transport, room, clientID, keyHex string, socksPort int, socksUser, socksPass string) error {
	rt := compat()
	if err := rt.SetProvider(carrier); err != nil {
		return err
	}
	if err := rt.SetTransport(transport); err != nil {
		return err
	}
	if err := rt.SetRoom(room); err != nil {
		return err
	}
	if clientID != "" {
		rt.SetDeviceID(clientID)
	}
	if err := rt.SetKey(keyHex); err != nil {
		return err
	}
	if err := rt.SetSocksListenHost("127.0.0.1"); err != nil {
		return err
	}
	if err := rt.SetSocksPort(socksPort); err != nil {
		return err
	}
	if socksUser != "" || socksPass != "" {
		if err := rt.SetSocksCredentials(socksUser, socksPass); err != nil {
			return err
		}
	}
	return rt.Start()
}

// WaitReady waits for readiness. Returns error only (Swift Bool success + NSError out-param).
func WaitReady(timeoutMillis int) error {
	return compat().WaitReady(timeoutMillis)
}

// Stop stops the runtime.
func Stop() { _ = compat().Stop(0) }
