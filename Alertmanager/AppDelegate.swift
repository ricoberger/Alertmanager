//
//  AppDelegate.swift
//  Alertmanager
//
//  Created by Rico Berger on 19.10.19.
//  Copyright © 2019 Rico Berger. All rights reserved.
//

import Cocoa

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength:NSStatusItem.squareLength)

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Render the button in the menu of macOS, using the "prometheus" image.
        // If the button is clicked we call the showAlerts function to show the WKWebView component with the rendered alerts.
        if let button = statusItem.button {
          button.image = NSImage(named:NSImage.Name("prometheus"))
          button.action = #selector(showAlerts)
        }
        
        // Initialize a single instance of the Alerts class, see: https://github.com/hpique/SwiftSingleton.
        _ = Alerts.sharedInstance
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        // Insert code here to tear down your application
    }

    @objc func showAlerts(_ sender: Any?) {
        // Create and show the popover menu, with the loaded alerts.
        let storyboard = NSStoryboard(name: "Main", bundle: nil)
        guard let vc = storyboard.instantiateController(withIdentifier: "ViewController") as? ViewController else {
            fatalError("Unable to find ViewController in the storyboard.")
        }

        guard let button = statusItem.button else {
            fatalError("Couldn't find status item button.")
        }

        let popoverView = NSPopover()
        popoverView.contentViewController = vc
        popoverView.behavior = .transient
        popoverView.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
    }
}

