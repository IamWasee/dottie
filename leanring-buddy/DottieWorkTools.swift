//
//  DottieWorkTools.swift
//  leanring-buddy
//
//  Voice tools for bigger work: projects (DottieProjects), teams of Dots
//  that split one job between them, and the picture library (saving a
//  picture of something on screen, finding saved pictures). CompanionManager
//  answers them (performWorkTool), since they need the roster, the projects
//  and the picture memory.
//

import Foundation

enum DottieWorkTools {
    static let functionNames: Set<String> = ["list_projects", "start_team", "save_picture", "find_pictures"]

    static var functionDeclarations: [[String: Any]] {
        [
            declaration(
                "list_projects",
                "List the user's projects (each thing helpers are building or working on has its own folder): names, files and who worked on them. Use it before saying a project does or doesn't exist."
            ),
            declaration(
                "start_team",
                "Split one big job between several helpers working at the same time in the same project folder, each doing its own part. Use it when the user asks for a team, or for a big job with clearly separate parts (a website: research, design and css, html, javascript; a launch: product page, marketing copy, social posts). Each part goes to its own helper; the helpers see each other's tasks and share the folder. For a normal-sized job, use start_helper instead. After calling, say in a few words who's doing what.",
                [
                    "goal": string("The whole job in one sentence, with the details the user gave."),
                    "project": string("The project's name: an existing one from list_projects to keep working on it, or a short new name (2-4 words) for something new."),
                    "parts": [
                        "type": "ARRAY",
                        "description": "2 to 5 parts, each for one helper.",
                        "items": [
                            "type": "OBJECT",
                            "properties": [
                                "helper": string("A short name for this helper's role, like 'Research', 'Design', 'HTML', 'JavaScript', 'Marketing'."),
                                "task": string("This part's task, written so it stands on its own: what to make, which files, and how it fits with the other parts.")
                            ],
                            "required": ["helper", "task"]
                        ]
                    ]
                ],
                required: ["goal", "project", "parts"]
            ),
            declaration(
                "save_picture",
                "Save a picture of something on the user's screen to remember it by name, like the pictures the user adds themselves. Use it when the user asks you to remember what something looks like or where it is, and on your own when remembering a thing's look will clearly help later (an item in a game you'll need to find again, a machine's spot on the map). Give the thing's position like point_at_element; leave x and y out to save the whole screen.",
                [
                    "name": string("1-4 words to know it by, like 'roll machines' or 'guardian core'."),
                    "description": string("One sentence: what it is, where it's from (the game or app) and how it looks, so it can be spotted again."),
                    "x": number("Horizontal position of the thing's center, 0 (left) to 1000 (right) of the frame."),
                    "y": number("Vertical position of the thing's center, 0 (top) to 1000 (bottom) of the frame."),
                    "label": string("A short name for the thing as it appears, to find its exact outline.")
                ],
                required: ["name", "description"]
            ),
            declaration(
                "find_pictures",
                "Search the saved pictures (the user's and yours) by what they show or where they're from, like 'golem game' or 'logo'. Returns names and descriptions; use the names in do_task_on_screen's reference_images or as a point_at_element label.",
                ["query": string("A few words for what to look for.")],
                required: ["query"]
            )
        ]
    }

    private static func declaration(_ name: String, _ description: String, _ properties: [String: [String: Any]] = [:], required: [String] = []) -> [String: Any] {
        var parameters: [String: Any] = ["type": "OBJECT", "properties": properties]
        if !required.isEmpty { parameters["required"] = required }
        return ["name": name, "description": description, "parameters": parameters]
    }

    private static func string(_ description: String) -> [String: Any] {
        ["type": "STRING", "description": description]
    }

    private static func number(_ description: String) -> [String: Any] {
        ["type": "NUMBER", "description": description]
    }
}
