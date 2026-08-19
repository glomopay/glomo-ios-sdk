import SwiftUI

struct ContentView: View {
    @StateObject private var model = CheckoutSampleViewModel()

    var body: some View {
        NavigationView {
            Form {
                Section("Checkout credentials") {
                    TextField("Enter public key", text: $model.publicKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Enter order ID or subscription ID", text: $model.identifier)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section("Checkout") {
                    Text("Checkout type is detected automatically from the order.")
                        .foregroundStyle(.secondary)
                    Toggle("Developer mode", isOn: $model.devMode)
                }

                Section {
                    Button("Start Checkout") {
                        model.startCheckout()
                    }
                    .frame(maxWidth: .infinity)
                    .disabled(model.isStarting)
                }

                Section("Last payment result") {
                    Text(model.status)
                        .foregroundStyle(.secondary)
                }

                Section("Events") {
                    if model.events.isEmpty {
                        Text("No events yet")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(model.events.enumerated()), id: \.offset) { _, event in
                            Text(event)
                                .font(.caption)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .navigationTitle("GlomoPay SDK Sample")
            .background(ViewControllerResolver { controller in
                model.setPresenter(controller)
            })
        }
        .navigationViewStyle(.stack)
    }
}

#Preview {
    ContentView()
}
