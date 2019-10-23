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
    var alertmanagerAlerts: [AlertmanagerAlerts] = []
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
    
    private func loadConfig() {
        do {
            // load the ".alertmanager.json" configuration file from the users home directory and decode the content into our config struct.
            let home = NSHomeDirectory()
            let conf = try String(contentsOfFile: home + "/.alertmanager.json", encoding: String.Encoding.utf8)
            let decoder = JSONDecoder()
            self.config = try decoder.decode(Config.self, from: conf.data(using: .utf8)!)
        } catch {
            self.configError = "Could not load configuration: " + error.localizedDescription
        }
    }
    
    @objc func loadAlerts() {
        self.loadErrors = []
        self.alertmanagerAlerts = []
        
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
                // to a list of alertmanagers.
                // NOTE: This should be changed to use a list of alert groups and add the Alertmanager name and url to these groups,
                // so we can sort the list by time.
                guard let dataResponse = data, error == nil else {
                    self.loadErrors.append("Could not load alerts for " + alertmanager.name + ": " + (error?.localizedDescription ?? "Response Error"))
                    return
                }
                
                do {
                    let stringData = String(data: dataResponse, encoding: .utf8)!
                    let decoder = JSONDecoder()
                    let alertGroups = try decoder.decode(AlertGroups.self, from: stringData.data(using: .utf8)!)
                    
                    self.alertmanagerAlerts.append(AlertmanagerAlerts(name: alertmanager.name, url: alertmanager.url, alertGroups: alertGroups))
                } catch {
                    self.loadErrors.append("Could not load alerts for " + alertmanager.name + ": " + error.localizedDescription)
                }
            }

            task.resume()
        }
    }
}

