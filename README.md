# MacHead - MacBook Headless Workstation Mode Manager

MacHead is a macOS utility designed to transform a MacBook with a damaged display, or one used as a dedicated desktop client, into a fully functional headless workstation/server (similar to a Mac mini). 

## Documents
* [Product Requirement Document (PRD)](file:///Users/waffle/project/MacHead/PRD.md)

## Key Features
1. **Headless Mode**: Disconnect the internal display using private CoreDisplay APIs and prevent clamshell sleep.
2. **External Display Management**: Lock the main menu bar and Dock to the external screen, and handle hotplug events.
3. **Power & Sleep Control**: Hold power assertions to prevent idle sleep and battery draining.
4. **Input/Output Device Management**: Optionally disable the internal keyboard, trackpad, camera, and microphone when external devices are connected.
