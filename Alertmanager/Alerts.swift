//
//  Alerts.swift
//  Alertmanager
//
//  Created by Rico Berger on 19.10.19.
//  Copyright © 2019 Rico Berger. All rights reserved.
//

import Foundation

class Alerts {
    static let sharedInstance: Alerts = Alerts()
    var timer = Timer()
    var alertGroups: AlertGroups = []
    var configError: String = ""
    var loadErrors: [String] = []
    var config: Config!
    
    private init() {
        loadConfig()
        loadAlerts()
        
        // Refresh the list of alerts after the configured refresh interval in seconds.
        let interval = self.config.refreshInterval
        timer = Timer.scheduledTimer(timeInterval: interval, target: self, selector: #selector(self.loadAlerts), userInfo: nil, repeats: true)
    }
    
    func loadConfig() {
        do {
            let home = NSHomeDirectory()
            let configFilePath = home + "/.alertmanager.json"
            
            // Check if the ".alertmanager.json" file exists. If no, create the file with the default configuration.
            if (!FileManager.default.fileExists(atPath: configFilePath)) {
                let file = FileManager()
                file.createFile(atPath: configFilePath, contents: Data(base64Encoded: "ewogICJyZWZyZXNoSW50ZXJ2YWwiOiA2MCwKICAic2V2ZXJpdHlMYWJlbCI6ICJzZXZlcml0eSIsCiAgInNldmVyaXR5SW5mbyI6ICJpbmZvIiwKICAic2V2ZXJpdHlXYXJuaW5nIjogIndhcm5pbmciLAogICJzZXZlcml0eUVycm9yIjogImVycm9yIiwKICAic2V2ZXJpdHlDcml0aWNhbCI6ICJjcml0aWNhbCIsCiAgInRpdGxlVGVtcGxhdGUiOiAiW3t7IG5hbWUgfCB1cHBlcmNhc2UgfX1dIFt7eyBsYWJlbHNbJ2NsdXN0ZXInXSB8IHVwcGVyY2FzZSB9fV0ge3sgbGFiZWxzWydhbGVydG5hbWUnXSB9fSIsCiAgImFsZXJ0VGVtcGxhdGUiOiAie3sgYW5ub3RhdGlvbnNbJ21lc3NhZ2UnXSB9fSIsCgogICJhbGVydG1hbmFnZXJzIjogWwogICAgewogICAgICAibmFtZSI6ICJBbGVydG1hbmFnZXIiLAogICAgICAidXJsIjogImh0dHA6Ly9sb2NhbGhvc3Q6OTA5MyIKICAgIH0KICBdCn0="))
            }
            
            // Load the ".alertmanager.json" configuration file from the users home directory and decode the content into our config struct.
            let conf = try String(contentsOfFile: configFilePath, encoding: String.Encoding.utf8)
            let decoder = JSONDecoder()
            self.config = try decoder.decode(Config.self, from: conf.data(using: .utf8)!)
        } catch {
            self.showNotification(title: "Could not load configuration", informativeText: "Could not load configuration: " + error.localizedDescription)
            self.configError = "Could not load configuration: " + error.localizedDescription
        }
    }
    
    func showNotification(title: String, informativeText: String) -> Void {
        let notification = NSUserNotification()

        notification.title = title
        notification.informativeText = informativeText
        notification.soundName = NSUserNotificationDefaultSoundName

        NSUserNotificationCenter.default.deliver(notification)
    }
    
    @objc func loadAlerts() {
        var newestAlert = ""
        if self.alertGroups.count > 0 {
            newestAlert = self.alertGroups[0].startsAt
        }
        
        self.loadErrors = []
        self.alertGroups = []
        
        // Load the alert groups for each configured alertmanager.
        for alertmanager in self.config.alertmanagers {
            let session = URLSession.shared
            let url = URL(string: alertmanager.url + "/api/v2/alerts/groups")!

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            
            // If an authentication type is specified we add the corresponding headers.
            if alertmanager.authType == "basic" {
                let loginString = String(format: "%@:%@", alertmanager.authUsername, alertmanager.authPassword)
                let loginData = loginString.data(using: String.Encoding.utf8)!
                let base64LoginString = loginData.base64EncodedString()
                request.setValue("Basic \(base64LoginString)", forHTTPHeaderField: "Authorization")
            } else if alertmanager.authType == "token" {
                request.setValue("Bearer \(alertmanager.authToken)", forHTTPHeaderField: "Authorization")
            }
            
            let task = session.dataTask(with: request) {(data, response, error) in
                // Decode the received json response into the alertGroups struct and add these groups + some Alertmanager details
                // to a list of alert groups.
                guard let dataResponse = data, error == nil else {
                    self.showNotification(title: "Could not load alerts", informativeText: "Could not load alerts for " + alertmanager.name + ": " + (error?.localizedDescription ?? "Response Error"))
                    self.loadErrors.append("Could not load alerts for " + alertmanager.name + ": " + (error?.localizedDescription ?? "Response Error"))
                    return
                }
                
                do {
                    let stringData = String(data: dataResponse, encoding: .utf8)!
                    let decoder = JSONDecoder()
                    var alertGroups = try decoder.decode(AlertGroups.self, from: stringData.data(using: .utf8)!)
                    
                    for (index, _) in alertGroups.enumerated() {
                        alertGroups[index].alertmanagerName = alertmanager.name
                        alertGroups[index].alertmanagerURL = alertmanager.url
                        alertGroups[index].alerts = alertGroups[index].alerts.sorted(by: { $0.startsAt > $1.startsAt })
                        alertGroups[index].startsAt = alertGroups[index].alerts[0].startsAt
                    }
                    
                    // Concatenate all alert groups from all Alertmanager instances and sort them.
                    // Then check if there is a newer alert in the list as in the old list. If yes, show a notification.
                    self.alertGroups.append(contentsOf: alertGroups)
                    self.alertGroups = self.alertGroups.sorted(by: { $0.startsAt > $1.startsAt })
                    
                    if newestAlert != "" && alertGroups.count > 0 && alertGroups[0].startsAt > newestAlert {
                        self.showNotification(title: "New alerts", informativeText: "New alerts for " + alertGroups[0].alertmanagerName)
                    }
                } catch {
                    self.showNotification(title: "Could not load alerts", informativeText: "Could not load alerts for " + alertmanager.name + ": " + error.localizedDescription)
                    self.loadErrors.append("Could not load alerts for " + alertmanager.name + ": " + error.localizedDescription)
                }
            }

            task.resume()
        }
    }
}

