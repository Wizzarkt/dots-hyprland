pragma Singleton
pragma ComponentBehavior: Bound

import qs.modules.common
import QtQuick
import Quickshell
import Quickshell.Io

/**
 * Simple polled resource usage service with RAM, Swap, and CPU usage.
 */
Singleton {
    id: root
	property real memoryTotal: 1
	property real memoryFree: 0
	property real memoryUsed: memoryTotal - memoryFree
    property real memoryUsedPercentage: memoryUsed / memoryTotal
    property real swapTotal: 1
	property real swapFree: 0
	property real swapUsed: swapTotal - swapFree
    property real swapUsedPercentage: swapTotal > 0 ? (swapUsed / swapTotal) : 0
    property real cpuUsage: 0
    property var previousCpuStats
    property real temperatureCelsius: -1
    property real igpuUsage: -1
    property real previousIgpuResidency: -1
    property real previousIgpuSampleTime: 0
    property string fileCpuTempPath: ""
    property string fileIgpuResidencyPath: ""

    property string maxAvailableMemoryString: kbToGbString(ResourceUsage.memoryTotal)
    property string maxAvailableSwapString: kbToGbString(ResourceUsage.swapTotal)
    property string maxAvailableCpuString: "--"

    readonly property int historyLength: Config?.options.resources.historyLength ?? 60
    property list<real> cpuUsageHistory: []
    property list<real> memoryUsageHistory: []
    property list<real> swapUsageHistory: []

    function kbToGbString(kb) {
        return (kb / (1024 * 1024)).toFixed(1) + " GB";
    }

    function updateMemoryUsageHistory() {
        memoryUsageHistory = [...memoryUsageHistory, memoryUsedPercentage]
        if (memoryUsageHistory.length > historyLength) {
            memoryUsageHistory.shift()
        }
    }
    function updateSwapUsageHistory() {
        swapUsageHistory = [...swapUsageHistory, swapUsedPercentage]
        if (swapUsageHistory.length > historyLength) {
            swapUsageHistory.shift()
        }
    }
    function updateCpuUsageHistory() {
        cpuUsageHistory = [...cpuUsageHistory, cpuUsage]
        if (cpuUsageHistory.length > historyLength) {
            cpuUsageHistory.shift()
        }
    }
    function updateHistories() {
        updateMemoryUsageHistory()
        updateSwapUsageHistory()
        updateCpuUsageHistory()
    }

	Timer {
		interval: 1
        running: true 
        repeat: true
		onTriggered: {
            // Reload files
            fileMeminfo.reload()
            fileStat.reload()

            // Parse memory and swap usage
            const textMeminfo = fileMeminfo.text()
            memoryTotal = Number(textMeminfo.match(/MemTotal: *(\d+)/)?.[1] ?? 1)
            memoryFree = Number(textMeminfo.match(/MemAvailable: *(\d+)/)?.[1] ?? 0)
            swapTotal = Number(textMeminfo.match(/SwapTotal: *(\d+)/)?.[1] ?? 1)
            swapFree = Number(textMeminfo.match(/SwapFree: *(\d+)/)?.[1] ?? 0)

            // Parse CPU usage
            const textStat = fileStat.text()
            const cpuLine = textStat.match(/^cpu\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)/)
            if (cpuLine) {
                const stats = cpuLine.slice(1).map(Number)
                const total = stats.reduce((a, b) => a + b, 0)
                const idle = stats[3]

                if (previousCpuStats) {
                    const totalDiff = total - previousCpuStats.total
                    const idleDiff = idle - previousCpuStats.idle
                    cpuUsage = totalDiff > 0 ? (1 - idleDiff / totalDiff) : 0
                }

                previousCpuStats = { total, idle }
            }

            // Parse CPU temperature from the coretemp package sensor
            if (root.fileCpuTempPath !== "") {
                fileCpuTemp.reload()
                const tempRaw = Number(fileCpuTemp.text().trim())
                root.temperatureCelsius = tempRaw > 0 ? Math.round(tempRaw / 1000) : -1
            }

            // Parse iGPU usage from RC6 residency deltas
            if (root.fileIgpuResidencyPath !== "") {
                fileIgpuResidency.reload()
                const residency = Number(fileIgpuResidency.text().trim())
                if (residency > 0) {
                    const now = Date.now()
                    if (root.previousIgpuResidency >= 0 && root.previousIgpuSampleTime > 0) {
                        const residencyDelta = residency - root.previousIgpuResidency
                        const timeDelta = now - root.previousIgpuSampleTime
                        if (timeDelta > 0 && residencyDelta >= 0) {
                            root.igpuUsage = Math.max(0, Math.min(1, 1 - residencyDelta / timeDelta))
                        }
                    }
                    root.previousIgpuResidency = residency
                    root.previousIgpuSampleTime = now
                }
            }

            root.updateHistories()
            interval = Config.options?.resources?.updateInterval ?? 3000
        }
	}

	FileView { id: fileMeminfo; path: "/proc/meminfo" }
    FileView { id: fileStat; path: "/proc/stat" }
    FileView { id: fileCpuTemp; path: root.fileCpuTempPath }
    FileView { id: fileIgpuResidency; path: root.fileIgpuResidencyPath }

    Process {
        id: findCpuMaxFreqProc
        environment: ({
            LANG: "C",
            LC_ALL: "C"
        })
        command: ["bash", "-c", "lscpu | grep 'CPU max MHz' | awk '{print $4}'"]
        running: true
        stdout: StdioCollector {
            id: outputCollector
            onStreamFinished: {
                root.maxAvailableCpuString = (parseFloat(outputCollector.text) / 1000).toFixed(0) + " GHz"
            }
        }
    }

    Process {
        id: findSensorPathsProc
        environment: ({
            LANG: "C",
            LC_ALL: "C"
        })
        // Print two lines: the coretemp package temp path and the iGPU RC6 residency path
        command: ["bash", "-c", "printf '%s\\n' \"$(for h in /sys/class/hwmon/hwmon*/name; do [ \"$(cat \"$h\" 2>/dev/null)\" = coretemp ] && echo \"${h%/name}/temp1_input\"; done | head -1)\" \"$(ls /sys/class/drm/card*/gt/gt0/rc6_residency_ms 2>/dev/null | head -1)\""]
        running: true
        stdout: StdioCollector {
            id: sensorOutputCollector
            onStreamFinished: {
                const lines = sensorOutputCollector.text.trim().split("\n")
                root.fileCpuTempPath = lines[0] ?? ""
                root.fileIgpuResidencyPath = lines[1] ?? ""
            }
        }
    }
}
