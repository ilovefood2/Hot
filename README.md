Hot
===

[![Build Status](https://img.shields.io/github/actions/workflow/status/macmade/Hot/ci-mac.yaml?label=macOS&logo=apple)](https://github.com/macmade/Hot/actions/workflows/ci-mac.yaml)
[![Issues](http://img.shields.io/github/issues/macmade/Hot.svg?logo=github)](https://github.com/macmade/Hot/issues)
![Status](https://img.shields.io/badge/status-active-brightgreen.svg?logo=git)
![License](https://img.shields.io/badge/license-mit-brightgreen.svg?logo=open-source-initiative)  
[![Contact](https://img.shields.io/badge/follow-@macmade-blue.svg?logo=twitter&style=social)](https://twitter.com/macmade)
[![Sponsor](https://img.shields.io/badge/sponsor-macmade-pink.svg?logo=github-sponsors&style=social)](https://github.com/sponsors/macmade)

### About

Hot is macOS menu bar application that displays the CPU speed limit due to thermal issues.

This fork of [macmade/Hot](https://github.com/macmade/Hot) adds **fan control** support.

#### Differences between the Intel and Apple Silicon versions

On an Intel machine, Hot will display the CPU temperature, CPU speed limit (throttling), scheduler limit and number of available CPUs.  
By default, the menu bar text will be colorized in orange if the CPU speed limit falls below 60%.

On Apple Silicon, these informations are not available.  
Along with the CPU temperature, Hot will display the system's thermal pressure.  
The menu bar text will be colorized in orange if the pressure is not nominal.

A graph view for all sensors may also be displayed on Apple Silicon.

![Apple Silicon Menu](Assets/menu-arm.png "Apple Silicon Menu")
![Sensors](Assets/sensors.png "Sensors")

#### Fan Control

The **Fans** menu displays the live RPM of each fan and lets you either
leave the fans under automatic system control (recommended), or force them
to 25%, 50%, 75% or 100% of their supported RPM range.

![Fans Menu](Assets/menu-fans.png "Fans Menu")

Changing fan settings requires an administrator password, as writing to the
SMC requires root privileges. Manual fan settings are restored to automatic
control when the app quits, and always reset on reboot.

Note that macOS protects itself regardless of fan settings: even at low
fan speeds, the machine will throttle before reaching unsafe temperatures.

#### CPU Frequency (Apple Silicon)

Enable **Display the CPU frequency in the menu bar** in the preferences to
show the live CPU clock speed next to the temperature.

![Preferences](Assets/preferences.png "Preferences")

Apple Silicon exposes no public API or `sysctl` for the current CPU clock, so
Hot derives it the same way tools like `powermetrics` do: it samples per-core
P-state residencies through the private `IOReport` framework (resolved at
runtime, so nothing private is linked) and weights them against the
per-cluster frequency tables read from the `pmgr` device-tree node. The value
shown is the average frequency of the cores that were active since the last
refresh, so it rises toward the cores' maximum under load and drops when the
machine is idle.

#### Building this fork

Git submodules have been vendored into the repository, so a plain
`git clone` (without `--recursive`) is sufficient. Open `Hot.xcodeproj`
and build the `Hot` scheme.

License
-------

Project is released under the terms of the MIT License.

Repository Infos
----------------

    Owner:          Jean-David Gadina - XS-Labs
    Web:            www.xs-labs.com
    Blog:           www.noxeos.com
    Twitter:        @macmade
    GitHub:         github.com/macmade
    LinkedIn:       ch.linkedin.com/in/macmade/
    StackOverflow:  stackoverflow.com/users/182676/macmade
