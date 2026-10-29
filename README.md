# T1D StepCount for National Parks

A little app for type one diabetics who want to go and visit National Parks.

## The problem

Blood glucose can drop after a while of walking around, but you never know when. That makes long walks in parks stressful: do you eat now, turn back, or keep going?

## What it does

Stepping tells you after how many steps — or miles / kilometers — your blood glucose will go down if you keep walking around in the park. Open the app before or during a walk and it shows:

- Your current glucose (mg/dL) from your Guardian sensor via CareLink
- Steps and miles until a 10 mg/dL drop
- Miles remaining until 70 mg/dL (conservative estimate)

So you can plan snacks and routes instead of guessing.

## How it works

- **Glucose:** Live Guardian readings via Medtronic CareLink (EU). Log in once in Settings; tokens are stored in the Keychain.
- **Activity:** Steps, cadence, and heart rate from HealthKit (works with iPhone alone, better with Apple Watch).
- **Prediction:** On-device Core ML quantile models (`pop_gbr_q10/q50/q90`) plus a small personal adapter predict your glucose drop curve over 0–10,000 steps. All inference happens on the phone.

## Use

1. Open the Xcode project (`Stepping.xcodeproj`) and run on your iPhone.
2. Allow HealthKit access when asked.
3. In Settings (gear icon), log in to CareLink and set your planned walk length.
4. Tap the red glucose block anytime to refresh.

Requirements: iOS with HealthKit, a Medtronic Guardian sensor paired with the Guardian app uploading to CareLink, Xcode to build.

## Safety

This is a personal helper, not a medical device. Predictions are estimates and can be wrong. If you feel low, treat first — don't wait for the app. Always follow your doctor's advice.

## License

Open source. See [LICENSE](LICENSE) (MIT).
