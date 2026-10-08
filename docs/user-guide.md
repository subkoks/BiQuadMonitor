# User guide

## Connect

1. Open the locally built `dist/preview/BiQuad Monitor.app`.
2. In **Settings → Router**, enter your Cudy's private IPv4 address, usually `192.168.10.1` for the original setup.
3. Enter the **router web-admin password**. Enable Keychain storage only if you want to save it on this Mac.
4. Match **Use HTTPS** to the router's working web connection. A page beginning with `http://` normally means leaving HTTPS unchecked. HTTPS needs a certificate trusted by macOS.
5. Click **Connect** and approve Local Network access if prompted.

The app connects over the local network; Wi-Fi and Ethernet can both work. It does not require SSH or a port change. After restarting the app, connect from Settings; if you opted into Keychain storage, use **Connect using saved password**.

**Demo** creates a clearly labeled simulated session without contacting a router or reading Keychain. Ordinary Demo sessions are saved locally. Diagnostic render/test modes use isolated storage.

## Read the signal

The full menu-bar preset displays:

```text
LTE BAND 3 | SINR 8 | RSRQ −9 | RSRP −96 | RSSI 23
```

| Metric | Meaning | Unit |
| --- | --- | --- |
| SINR | Desired signal relative to interference and noise | dB |
| RSRQ | Reference signal quality | dB |
| RSRP | Reference signal power | dBm |
| RSSI | Received strength reported by the router | Raw index unless the response explicitly supplies dBm |

A higher RSRP or RSRQ value includes a less-negative value. RSSI alone is not a quality score. Compare SINR, RSRQ and RSRP together; the app does not measure throughput or promise a speed improvement.

The compact tuner shows the current values and 60-second means from matching radio context. A dash means unavailable. **Paused**, **Stale**, **Offline**, **Sign in required** and **No service** are explicit states; unavailable current values do not become zero. Historical means and charts may remain visible.

Click the menu-bar readings to open the compact tuner. With an app window active:

| Shortcut | Action |
| --- | --- |
| ⌘1 | Compact tuner |
| ⌘2 | Signal workspace |
| ⌘, | Settings |
| ⌘Q | Quit and finish the current collection session |

All three windows have standard title bars and can be moved or resized. Their positions are fitted to an available screen when opened or when display configuration changes.

## Signal workspace

**Live signals** contains four history charts with linked hover cursors. Choose 1 minute, 5 minutes, 30 minutes, 1 hour or Session. The radio inspector shows band, cell and supported metadata. Add a timestamped observation to record an antenna adjustment or environmental change.

Lines break at missing values, connection gaps, pauses and radio-context changes. Long histories are simplified for display; exports preserve stored samples. The on-screen history is limited to the most recent 10,000 readings.

Pause stops polling and ends an active trial as incomplete while preserving its data. Resume continues the session. Sleep pauses active collection; wake resumes collection that was running before sleep. A deliberate manual pause remains paused.

## Antenna Lab

1. Name the first antenna position and optionally enter orientation and notes.
2. Select a settling period and recording duration. Defaults are 60 seconds settling and 120 seconds recording.
3. Click **Start trial** and keep the antenna still. Settling samples are stored with their phase but excluded from comparisons.
4. The first completed trial becomes the reference. Move the antenna and record another trial.
5. Select **Set reference** and **Compare** to inspect medians, P10–P90, interquartile range and change for each metric.

Positive change means a higher reading. The change column is suppressed if either trial has unknown or changing band/cell/units, or if the two trials do not match. This prevents treating a network handover as an antenna gain. Sample counts are shown; missing values are excluded separately for each metric.

**Stop trial · keep partial data** preserves an incomplete trial. Experiment sessions are pinned automatically. Older trials can be selected through **Sessions → Inspect** and then compared in Antenna Lab.

## History and export

**Sessions** lists recent collections. Inspect one to view saved charts, trials and events. The list shows up to 1,000 sessions. The view loads the most recent 10,000 readings and simplifies each plotted metric to at most 800 points. A session export includes every stored reading, including those outside the visible chart.

Use **Export…** while viewing the live session or an inspected saved session. Choose CSV or JSON. Cell identifiers and session names/trial notes/observations are excluded by default. Enable those options only when you intend to include them. Demo data remains identified as simulated.

Data lives in `~/Library/Application Support/BiQuadMonitor/measurements.sqlite`. Keep the app closed when making a normal filesystem backup of this directory. The database may have SQLite companion files while the app is running.

In **Settings → Data & sound**, choose a 7-, 30- or 90-day cleanup threshold. Nothing is deleted merely by selecting a threshold: use the explicit cleanup button to remove older, closed, unpinned sessions. Pinning protects a session from routine cleanup. Export important experiments before unpinning them.

The optional SINR target sound is off by default. When enabled, fresh readings at or above the target play at most one tone per 10 seconds.

## Connection troubleshooting

| Symptom | Check |
| --- | --- |
| Router unreachable | Mac is on the router's LAN; address is correct; Local Network permission for BiQuad Monitor is enabled |
| HTTPS/certificate error | Protocol matches the router and the certificate is trusted; certificate validation cannot be bypassed |
| Sign in required | Reconnect using the web-admin password or the app's saved Keychain entry |
| Cellular page could not be read | Router model, firmware or response format may differ from the supported adapter; record the safe error text |
| No service | Router is reachable but reports no cellular connection |
| Browser works, app fails | Check the app's own permission, authentication and supported firmware; a LAN cable is not automatically the solution |

Diagnostics includes **Read now**, safe connection information and recent events. Network failures back off retries up to 60 seconds. Keep macOS firewall and other security controls enabled; changing global protections is not a required setup step.

Do not include a password or router backup when reporting a failure. See [Compatibility](compatibility.md) and [Security](../SECURITY.md).
