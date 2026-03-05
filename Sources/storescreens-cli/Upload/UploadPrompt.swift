import Foundation

struct UploadPrompt {
    let manifest: CaptureManifest
    let outputDir: URL
    let logger: Logger

    func run() async {
        logger.log("")
        logger.header("Design App Store screenshots")

        guard promptYesNo("Would you like to design App Store Connect screenshots at storescreens.app?") else {
            return
        }

        guard let email = promptEmail() else { return }

        let uploader = WebUploader(logger: logger)

        do {
            // Step 1: Initiate upload session
            logger.log("Connecting to storescreens.app...", level: .info)
            let initResponse = try await uploader.initiate(email: email)

            let token: String

            if initResponse.status == "ready" {
                token = initResponse.upload_token!
            } else if initResponse.status == "verification_required" {
                // Existing user — needs verification
                logger.log("A verification code has been sent to \(email).", level: .info)
                guard let code = promptCode() else { return }

                let verifyResponse = try await uploader.verify(email: email, code: code)
                guard let t = verifyResponse.upload_token else {
                    logger.log("Verification failed.", level: .error)
                    return
                }
                token = t
            } else {
                logger.log("Unexpected response from server.", level: .error)
                return
            }

            // Step 2: Upload screenshots
            let totalScreenshots = manifest.devices.reduce(0) { $0 + $1.screenshots.count }
            logger.log("Uploading \(totalScreenshots) screenshots...", level: .info)

            let uploadResponse = try await uploader.upload(token: token, manifest: manifest, outputDir: outputDir)

            if let url = uploadResponse.url {
                logger.log("Screenshots uploaded successfully!", level: .success)
                logger.log("Open your project: \(url)", level: .info)
            } else {
                logger.log("Screenshots uploaded.", level: .success)
            }
        } catch {
            logger.log("Upload failed: \(error.localizedDescription)", level: .error)
            logger.log("You can still use your local screenshots in \(outputDir.path).", level: .info)
        }
    }

    // MARK: - Interactive prompts

    private func promptYesNo(_ question: String) -> Bool {
        print("\n  \(question) (y/n) ", terminator: "")
        guard let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() else {
            return false
        }
        return answer == "y" || answer == "yes"
    }

    private func promptEmail() -> String? {
        print("  Enter your email address: ", terminator: "")
        guard let email = readLine()?.trimmingCharacters(in: .whitespaces), !email.isEmpty else {
            logger.log("No email provided.", level: .warning)
            return nil
        }
        // Basic email format check
        guard email.contains("@") && email.contains(".") else {
            logger.log("That doesn't look like a valid email address.", level: .warning)
            return nil
        }
        return email
    }

    private func promptCode() -> String? {
        print("  Enter the 6-digit code: ", terminator: "")
        guard let code = readLine()?.trimmingCharacters(in: .whitespaces), !code.isEmpty else {
            logger.log("No code provided.", level: .warning)
            return nil
        }
        return code
    }
}
