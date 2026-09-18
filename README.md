# Sami 🛍️

**Sami** (formerly StylePOS) is an **offline-first Point of Sale app for clothing shops**, built with **Flutter**.
Runs on **Android** (phone/tablet at the counter) and **Windows** (desktop),
with a local SQLite database — no internet or server required.

![Flutter](https://img.shields.io/badge/Flutter-3.47+-02569B?logo=flutter)
![Platform](https://img.shields.io/badge/Platform-Android%20%7C%20Windows-4CAF50)
![CI](https://img.shields.io/badge/CI-GitHub_Actions-2088FF?logo=githubactions)

---

## Features

| Module | What it does |
|---|---|
| **POS / Sell** | Touch product grid, barcode/SKU scan-in (works with USB & Bluetooth keyboard-wedge scanners), size/color variant picker, cart with quantity steppers, order discounts, Cash / Card / Mobile money, change calculator |
| **Inventory** | Products with **size × color variants**, each with own SKU, barcode, price, cost and stock; categories; stock in/out adjustments with audit trail; low-stock alerts |
| **Sales history** | Filterable by day/7/30/all, searchable, full receipt detail, admin refunds that restore stock |
| **Receipts** | 80mm roll-style **PDF receipt** — save, print (OS print dialog), share (Android share sheet) |
| **Customers** | Contact book, loyalty points (1 point per amount spent, configurable), purchase history, start-a-sale-for-customer |
| **Reports** | Revenue today / 7d / 30d, orders, average basket, revenue trend line chart, top products bar chart, category share pie |
| **Users & roles** | Admin (full access) vs Cashier (sell + customers + sales history), password change, staff management, account deactivation |

Everything works **offline**: data lives in SQLite on the device
(`sqflite` on Android, `sqlite3` FFI on Windows).

## First run

The app seeds a default admin account and a starter catalog so you can
try selling immediately:

| | |
|---|---|
| **Email** | `admin@stylepos.app` |
| **Password** | `admin123` |

> ⚠️ **Change the admin password right away** (lock icon in the top bar).

Then adjust your shop under **Settings**: shop name, address, phone,
currency (code + symbol, e.g. `KES` / `KSh`), tax rate, loyalty step and
receipt footer. Change the default password for staff accounts you create.

## Running from source

Prerequisite: [Flutter SDK](https://docs.flutter.dev/get-started/install) 3.47+.

```bash
git clone <your-repo-url>
cd stylepos
flutter pub get

# Android device / emulator connected:
flutter run

# Windows desktop:
flutter run -d windows
```

### Useful commands

```bash
flutter analyze     # static analysis (clean: 0 issues)
flutter test        # unit + end-to-end database tests
flutter build apk --release          # Android installer
flutter build windows --release      # Windows build
```

## Building with GitHub Actions (no local setup needed)

The included workflow [`.github/workflows/build.yml`](.github/workflows/build.yml)
does everything in the cloud:

| Trigger | What you get |
|---|---|
| Push to `main` (or manual *Run workflow*) | **Analyze → Test → Build** on both platforms. Download **`Sami-android-apk`** and **`Sami-windows-x64`** artifacts from the run's page. |
| Push a tag `v*` (e.g. `v1.0.0`) | Everything above **plus a GitHub Release** with `Sami-android-arm64.apk` and `Sami-windows-x64.zip` attached. |

Release a new version:

```bash
git tag v1.0.0
git push origin v1.0.0
```

> The Windows zip contains `sami.exe` + the runtime DLLs — unzip it
> anywhere on Windows 10/11 and run the exe. The APK installs directly on
> any Android 7+ device (allow "install from unknown sources").

## Project structure

```
lib/
├── main.dart                  # bootstrap, providers, theme
├── models/                    # User, Product/Variant, Customer, Sale, Category
├── data/database.dart         # SQLite schema, seed data, platform factory
├── services/
│   ├── hash.dart              # salted SHA-256 password hashing
│   └── receipt_service.dart   # PDF receipt generation / print / share
├── state/                     # provider state management
│   ├── auth.dart  settings.dart  catalog.dart  cart.dart
│   ├── sales.dart  customers.dart  nav.dart
└── screens/
    ├── login_screen.dart  home_shell.dart
    ├── pos/                   # sell screen, cart panel, checkout, variants
    ├── products/              # inventory, product editor, stock adjust
    ├── sales/                 # history + receipt detail + refunds
    ├── customers/             # CRM + loyalty
    ├── reports/               # KPI cards + fl_chart charts
    └── settings/              # shop settings + staff accounts
```

## Security notes

- Passwords are stored as salted SHA-256 hashes; sessions persist per device.
- Release APK is signed with the debug keystore for convenience — before
  publishing to Play Store, add your own keystore (see
  [Android signing docs](https://docs.flutter.dev/deployment/android#signing-the-app)).

## Roadmap ideas

- Camera barcode scanning on Android (`mobile_scanner`)
- Bluetooth ESC/POS thermal printer output
- CSV export of sales & inventory
- Cloud sync (e.g. Supabase) for multi-device stock
- Product images
