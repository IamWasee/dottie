import re, sys
p = "lab/PointingRefiner.swift"
s = open(p).read()
old = """        guard let (responseData, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return parseBox(from: textFromServerSentEvents(responseData))"""
new = """        let result: (Data, URLResponse)
        do { result = try await URLSession.shared.data(for: request) } catch { FileHandle.standardError.write("VISION ERR \\(error)\\n".data(using: .utf8)!); return nil }
        let (responseData, response) = result
        let text = textFromServerSentEvents(responseData)
        FileHandle.standardError.write("VISION status=\\((response as? HTTPURLResponse)?.statusCode ?? -1) parsed=\\(String(describing: parseBox(from: text))) text=\\(text.prefix(200)) raw=\\(String(decoding: responseData.prefix(400), as: UTF8.self))\\n".data(using: .utf8)!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return parseBox(from: text)"""
assert old in s
open(p, "w").write(s.replace(old, new))
p = "lab/DottieScreenTaskRunner.swift"
s = open(p).read()
old = """        let (responseData, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1"""
new = """        let started = Date()
        let (responseData, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        FileHandle.standardError.write("TASK status=\\(statusCode) t=\\(-started.timeIntervalSinceNow) body=\\(requestBody.count) raw=\\(String(decoding: responseData.prefix(600), as: UTF8.self).replacingOccurrences(of: "\\n", with: " "))\\n".data(using: .utf8)!)"""
assert old in s
s = s.replace(old, new)
open(p, "w").write(s)
print("patched")
