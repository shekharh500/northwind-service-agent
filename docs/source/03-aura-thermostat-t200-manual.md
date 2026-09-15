---
document: NWH-MAN-T200
firmware: 4.1.x
published: February 2026
notice: Northwind Home is a fictitious company. This document contains sample content for demonstration purposes only.
---

# Aura Smart Thermostat T200 User and Troubleshooting Manual

This manual covers installation, setup and troubleshooting for the Aura Smart Thermostat T200 running firmware 4.1.x.

## 1. Product overview

The Aura Smart Thermostat T200 is a Wi-Fi-connected thermostat for low-voltage (24V) heating and cooling systems. It supports scheduling, geofencing, energy reports and voice control through the Beacon Smart Speaker range.

### Technical specifications

| Item | Specification |
|------------------|----------------------------------------|
| Supply voltage | 24V AC, or battery backup using two AAA batteries (maintains schedule and clock only) |
| Display | 3.5-inch color touchscreen |
| Wi-Fi | 2.4 GHz 802.11 b/g/n. 5 GHz networks are not supported. |
| Temperature accuracy | ±0.5 °C |
| Humidity sensor range | 10 to 90% relative humidity |
| Operating temperature | 0 to 40 °C |
| Dimensions | 90 × 90 × 24 mm |
| Weight | 180 g |

## 2. System compatibility

The T200 works with most 24V gas, oil and electric forced-air systems, heat pumps with auxiliary heat, and hot-water boilers with a 24V control circuit.

The thermostat requires a common wire (C wire) for continuous power. If no C wire is available, install the Aura Power Adapter Kit (sold separately).

> **Caution:** The T200 is not compatible with line-voltage (120V or 240V) baseboard heaters or millivolt fireplace systems. Connecting the thermostat to line voltage will permanently damage it and is not covered by the warranty.

## 3. Installation summary

Installation normally takes 30 to 45 minutes. Professional installation by a Northwind installation partner can be booked through the customer portal.

1. Turn off power to the heating and cooling system at the breaker.
2. Remove the old thermostat and photograph the existing wiring.
3. Label each wire using the stickers in the box.
4. Mount the base plate and connect the wires to the matching terminals.
5. Attach the display, restore power and follow the on-screen setup.

## 4. Connecting to Wi-Fi

1. On the thermostat, open Settings > Network.
2. Select your 2.4 GHz network and enter the password.
3. Open the Northwind Home app, tap Add Device and scan the QR code shown on the thermostat.

> **Note:** If your router broadcasts a single combined network name for 2.4 GHz and 5 GHz, temporarily enable a separate 2.4 GHz network name during setup.

## 5. Error codes

| Code | Meaning | What to do |
|------|-----------------------------|------------------------------------------|
| E1 | Temperature sensor fault | Restart the thermostat. If E1 returns within 24 hours, the device may be defective; open a warranty claim. |
| E2 | No power on the C wire | Check the breaker and the C wire connection at both the thermostat and the furnace control board. |
| E3 | Wi-Fi authentication failed | Re-enter the Wi-Fi password and confirm the network is 2.4 GHz. |
| E4 | Cloud service unreachable. The thermostat is connected to Wi-Fi but cannot reach Northwind servers. | Check the router's internet connection. Schedules continue to run locally. |
| E5 | Heat pump reversing valve misconfigured | In Settings > Equipment, switch the O/B valve setting between "Energize on cool" and "Energize on heat." |
| E6 | Low backup battery | Replace both AAA batteries within 7 days to keep the clock and schedule during power outages. |

## 6. Resetting the thermostat

| Reset | How to do it | What happens |
|----------------|--------------------------------------|------------------------------|
| Restart | Press and hold the display for 10 seconds until the logo appears. | Settings and schedules are kept. |
| Network reset | Settings > Network > Reset Network | Wi-Fi details are removed; schedules are kept. |
| Factory reset | Settings > System > Factory Reset, then confirm with the 4-digit code shown on screen. | All settings, schedules and account links are erased. |

After a factory reset, the device must be removed from the app and added again.

## 7. Energy saving features

Eco Mode uses phone geofencing to lower heating by 2 °C and raise cooling by 2 °C when nobody is home. Customers typically save between 8 and 12% on heating and cooling costs with Eco Mode enabled.

Monthly energy reports are available in the app on the 3rd day of each month. Each report compares usage against the previous month and against similar homes nearby.

## 8. Firmware updates

Firmware updates install automatically between 2 a.m. and 4 a.m. local time. To check the installed version, open Settings > System > About.

Firmware 4.1.2 fixed an issue where the E4 code appeared incorrectly after a router restart.

## 9. Getting help

If troubleshooting does not resolve the problem, contact support through the customer portal assistant. Have the device serial number (Settings > System > About) and a photo of the wiring ready. The assistant can escalate to a live specialist when needed.
