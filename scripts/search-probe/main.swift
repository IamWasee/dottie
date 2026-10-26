let questions = ["who won the 2025 world series", "how do i download releases on github", "how to turn on subtitles in vlc", "weather in london today", "latest macos version"]
let semaphore = DispatchSemaphore(value: 0)
Task {
    for question in questions {
        let answer = await DottieWebSearch.search(question)
        print("== \(question)\n" + answer.prefix(500) + "\n")
    }
    semaphore.signal()
}
semaphore.wait()
