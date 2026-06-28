# Merge-Plan: My Price Log → KitchenOwl

**Datum:** 26.06.2026
**Status:** Warte auf Freigabe

---

## 1. Bestätigte Anforderungen

| # | Anforderung | Entscheidung |
|---|---|---|
| 1 | KitchenOwl bleibt Basis | ✅ KitchenOwl Flask-Backend + Flutter-Frontend |
| 2 | My Price Log voll integrieren | ✅ Alle Preislog-Funktionen in KitchenOwl |
| 3 | Supabase | ❌ **Nicht verwendet** – Flask-Backend wird erweitert |
| 4 | Karten-Anbieter | **OpenStreetMap** via `flutter_map` |
| 5 | Berechtigungsmodell | **Bestehendes KitchenOwl-Modell** (Owner/Admin/Member) |
| 6 | Kommentare | Rezepte, Preiseinträge, Shops/Places, Map-Pins |
| 7 | Map-Pins | Allgemeine Pins mit Kommentaren, optionaler Link zu Shops |
| 8 | Einladungen | Bestehendes Household-System |
| 9 | Plattformen | Web, Android, iOS (wie KitchenOwl) |

---

## 2. Architektur-Entscheidung: Kein Supabase

KitchenOwl hat bereits alles, was Supabase bieten würde:

| Supabase-Feature | KitchenOwl-Äquivalent | Status |
|---|---|---|
| SQL-Datenbank | SQLAlchemy + SQLite/PostgreSQL (~50 Migrationen) | ✅ Vorhanden |
| Authentication | JWT (Access/Refresh) + OIDC (Google, Apple, Custom) | ✅ Vorhanden |
| Realtime Sync | Socket.IO WebSockets + RabbitMQ Multi-Instance | ✅ Vorhanden |
| Storage | File-Upload/Download API | ✅ Vorhanden |
| Row-Level Security | `DbModelAuthorizeMixin` (Haushalt-basiert) | ✅ Vorhanden |

**Vorteile:** Kein Rewrite, keine Dual-Backend-Komplexität, keine Supabase-Migration.

---

## 3. Empfohlene Architektur

### 3.1 Übersicht

```
┌── Flutter Frontend (KitchenOwl + neue Features) ─────────────┐
│  Neu:                                                            │
│  ├─ pages/price_log/         Preise, Shops, Karte, Kommentare  │
│  ├─ cubits/price_*.dart      State Management (Bloc-Pattern)   │
│  ├─ models/price_*.dart      Datenmodelle (Equatable)          │
│  ├─ services/api/price_*.dart API-Calls (Extension auf ApiService) │
│  └─ widgets/price_*.dart     UI-Komponenten (KitchenOwl-Stil)  │
│                                                                   │
│  Unverändert: Einkaufslisten, Rezepte, Planer, Expenses, Auth   │
└──────────────────────┬───────────────────────────────────────┘
                       │ HTTP REST + Socket.IO WebSockets
┌── Python Flask Backend (erweitert) ─────────────────────────┐
│  Neu:                                                            │
│  ├─ models/price_dataset.py, price_source.py, price_item.py    │
│  ├─ models/price_entry.py, price_history.py                    │
│  ├─ models/comment.py, map_pin.py                              │
│  ├─ controller/price_log/          REST-API (Pattern wie Expense) │
│  ├─ controller/comment_controller.py                           │
│  ├─ controller/map_pin_controller.py                           │
│  ├─ sockets/price_log_socket.py    Socket.IO-Events            │
│  └─ migrations/                    Neue Alembic-Migrationen    │
│                                                                   │
│  Unverändert: Auth, Households, Shopping, Recipes, Expenses    │
└────────────────────────────────────────────────────────────┘
                       │
┌── PostgreSQL / SQLite (erweitert) ──────────────────────────┐
│  7 neue Tabellen + Erweiterungen an bestehenden Tabellen      │
└────────────────────────────────────────────────────────────┘
```

### 3.2 Warum keine separate "Price Log" Sektion?

Das Konzept von My Price Logs "DataSet" entspricht strukturell einem KitchenOwl-Household:
- Ein DataSet = eine Sammlung von Items + Sources + Prices
- Ein Household = eine Sammlung von Items + Rezepten + Einkaufslisten + Expenses

**Entscheidung:** Preislog-Features werden **innerhalb des Households** integriert – nicht als separates DataSet-Konzept. Jedes Household hat also zusätzlich:
- Shops/Quellen (`price_source`)
- Preis-Items (`price_item`)
- Preiseinträge (`price_entry`)
- Preishistorie (`price_history`)

Das vermeidet Redundanz und macht das Berechtigungsmodell trivial: Household-Member sehen alle Preisdaten ihres Households.

---

## 4. Datenmodell — Neue Tabellen

### 4.1 `price_source` (Shop/Laden)

```python
class PriceSource(Model, DbModelAuthorizeMixin):
    __tablename__ = "price_source"
    
    id: int (PK)
    name: str(128)
    household_id: int (FK → household.id, NOT NULL, INDEX)
    loyalty_type: str(16)  # "NONE", "BONUS", "DISCOUNT"
    loyalty_multiplier: float  # 1.0 für NONE, <1.0 für BONUS/DISCOUNT
    notes: str
    created_at: datetime
    updated_at: datetime
```

**Beziehung zu `map_pin`:** Ein `map_pin` kann optional auf eine `price_source` verweisen (1:1 oder M:1).

### 4.2 `price_item` (Preis-Vergleichs-Item)

```python
class PriceItem(Model, DbModelAuthorizeMixin):
    __tablename__ = "price_item"
    
    id: int (PK)
    name: str(128)
    household_id: int (FK → household.id, NOT NULL, INDEX)
    default_unit: int  # MeasurementUnit-Enum-Wert
    quantity_type: str(16)  # "ITEM", "WEIGHT", "VOLUME"
    allow_multipack: bool (default False)
    notes: str
    created_at: datetime
    updated_at: datetime
```

**Wichtig:** `price_item` ist getrennt vom bestehenden KitchenOwl `item` (Einkaufslisten-Items). Das sind unterschiedliche Konzepte:
- `item` = "Milch" auf dem Einkaufszettel
- `price_item` = "Vollmilch 3,5%" als Preisvergleichs-Produkt

### 4.3 `price_entry` (Preiseintrag)

```python
class PriceEntry(Model, DbModelAuthorizeMixin):
    __tablename__ = "price_entry"
    
    id: int (PK)
    household_id: int (FK → household.id, NOT NULL, INDEX)
    price_item_id: int (FK → price_item.id, CASCADE)
    price_source_id: int (FK → price_source.id, CASCADE)
    price: float  # Regalpreis in Household-Währung
    count: int (default 1)  # Pack-Anzahl
    quantity_in_base_unit: float  # Packungsgröße in Basis-Einheit
    user_unit: int  # MeasurementUnit, vom Benutzer gewählt
    confirmed_at: datetime
    notes: str
    created_by: int (FK → user.id)
    created_at: datetime
    updated_at: datetime
    
    # Unique constraint: (price_item_id, price_source_id)
```

### 4.4 `price_history` (Preishistorie)

```python
class PriceHistory(Model):
    __tablename__ = "price_history"
    
    id: int (PK)
    price_entry_id: int  # KEIN FK – Einträge überleben Löschung
    household_id: int (FK → household.id, CASCADE, INDEX)
    price_item_id: int (FK → price_item.id, CASCADE, INDEX)
    price_source_id: int (FK → price_source.id, CASCADE, INDEX)
    price: float
    count: int
    quantity_in_base_unit: float
    user_unit: int
    confirmed_at: datetime
    notes: str
    modified_by: int (FK → user.id)
    modified_at: datetime
```

### 4.5 `comment` (Kommentare — polymorph)

```python
class Comment(Model):
    __tablename__ = "comment"
    
    id: int (PK)
    entity_type: str(32)  # "recipe", "price_entry", "price_source", "map_pin", "expense"
    entity_id: int  # ID der referenzierten Entität
    household_id: int (FK → household.id, NOT NULL, INDEX)
    body: str  # Markdown-Inhalt
    created_by: int (FK → user.id)
    created_at: datetime
    updated_at: datetime
```

**Polymorphes Design:** Ein Kommentar referenziert über `entity_type` + `entity_id` die Zieltabelle. Dies folgt dem Muster des bestehenden `report`-Modells in KitchenOwl.

**Betroffene Entitäten:**
- `recipe` — Rezept-Kommentare
- `price_entry` — Diskussion zu einem Preis
- `price_source` — Diskussion zu einem Shop
- `map_pin` — Diskussion zu einem Karten-Pin
- `expense` — Diskussion zu einer Ausgabe

### 4.6 `map_pin` (Karten-Pin)

```python
class MapPin(Model, DbModelAuthorizeMixin):
    __tablename__ = "map_pin"
    
    id: int (PK)
    household_id: int (FK → household.id, NOT NULL, INDEX)
    name: str(128)
    description: str  # Markdown
    latitude: float
    longitude: float
    price_source_id: int | None (FK → price_source.id, SET NULL)
    color: str(7) | None  # Hex-Farbe, nullable
    icon: str(64) | None  # Icon-Name
    created_by: int (FK → user.id)
    created_at: datetime
    updated_at: datetime
```

**Beziehung:** `map_pin.price_source_id → price_source.id` (optional). Wenn gesetzt, zeigt der Pin beim Antippen die verknüpften Preiseinträge des Shops an.

### 4.7 Erweiterung bestehender Tabellen

Die Tabelle `household` bekommt ein neues Feature-Flag:
```python
# Neue Spalte in household:
price_log_feature: bool (default False)
```

Analog zum bestehenden `expenses_feature` und `planner_feature`. Der Household-Admin kann das Preislog-Feature aktivieren/deaktivieren.

### 4.8 MeasurementUnit-Enum (Python)

```python
from enum import IntEnum

class MeasurementUnit(IntEnum):
    # ITEM
    EACH = 101
    EACH10 = 102
    EACH100 = 103
    # WEIGHT - Metric
    G = 201
    G100 = 202
    KG = 203
    # WEIGHT - Imperial/US
    OZ = 211
    LB = 212
    # VOLUME - Metric
    ML = 301
    ML100 = 302
    L = 303
    # VOLUME - Imperial
    IMPERIAL_FLOZ = 311
    IMPERIAL_PINT = 312
    IMPERIAL_GAL = 313
    # VOLUME - US Customary
    US_FLOZ = 321
    US_PINT = 322
    US_GAL = 323
    
    @property
    def quantity_type(self) -> str: ...
    
    @property
    def to_base(self) -> float: ...
    
    @property
    def unit_family(self) -> str: ...  # "ITEM", "METRIC", "IMPERIAL", "US_CUSTOMARY"
```

---

## 5. API-Design (Backend)

### 5.1 Preislog-Controller (Pattern wie Expense-Controller)

**Zwei Blueprints pro Entität:**

| Blueprint | URL-Präfix | Auth |
|---|---|---|
| `price_source` | `/price-source/<id>` | `checkAuthorized()` auf Model |
| `price_source_household` | `/household/<id>/price-source` | `@authorize_household()` |
| `price_item` | `/price-item/<id>` | `checkAuthorized()` |
| `price_item_household` | `/household/<id>/price-item` | `@authorize_household()` |
| `price_entry` | `/price-entry/<id>` | `checkAuthorized()` |
| `price_entry_household` | `/household/<id>/price-entry` | `@authorize_household()` |

**Endpunkte (exemplarisch für price_entry):**

| Methode | Pfad | Beschreibung |
|---|---|---|
| GET | `/household/<id>/price-entry` | Liste (mit Filter: item_id, source_id) |
| GET | `/household/<id>/price-entry/analysis` | Preisanalyse (IQR) für ein Item |
| GET | `/price-entry/<id>` | Einzeleintrag |
| GET | `/price-entry/<id>/history` | Preishistorie |
| POST | `/household/<id>/price-entry` | Neuer Preiseintrag |
| POST | `/price-entry/<id>` | Update Preiseintrag |
| DELETE | `/price-entry/<id>` | Löschen |
| POST | `/price-entry/<id>/confirm` | Preis bestätigen (confirmed_at = now) |
| POST | `/price-entry/<id>/revert` | Auf vorherige Version zurücksetzen |

### 5.2 Kommentar-Controller

| Methode | Pfad | Beschreibung |
|---|---|---|
| GET | `/household/<id>/comment?entity_type=X&entity_id=Y` | Kommentare für Entität |
| POST | `/household/<id>/comment` | Neuen Kommentar erstellen |
| POST | `/comment/<id>` | Kommentar bearbeiten |
| DELETE | `/comment/<id>` | Kommentar löschen |

### 5.3 Map-Pin-Controller

| Methode | Pfad | Beschreibung |
|---|---|---|
| GET | `/household/<id>/map-pin` | Alle Pins (mit Bounding-Box-Filter) |
| GET | `/map-pin/<id>` | Einzelner Pin |
| POST | `/household/<id>/map-pin` | Pin erstellen |
| POST | `/map-pin/<id>` | Pin bearbeiten |
| DELETE | `/map-pin/<id>` | Pin löschen |

### 5.4 Socket.IO Events (Echtzeit-Sync)

| Event | Richtung | Beschreibung |
|---|---|---|
| `price_entry:add` | Server → Client | Neuer Preiseintrag im Household |
| `price_entry:update` | Server → Client | Preiseintrag aktualisiert |
| `price_entry:delete` | Server → Client | Preiseintrag gelöscht |
| `comment:add` | Server → Client | Neuer Kommentar |
| `map_pin:add` | Server → Client | Neuer Pin |
| `map_pin:update` | Server → Client | Pin aktualisiert |
| `map_pin:delete` | Server → Client | Pin gelöscht |

Events werden über Socket.IO-Rooms (`household/{id}`) an alle Household-Mitglieder verteilt – identisch zum bestehenden Shopping-List-Sync.

---

## 6. Preisanalyse-Algorithmus (Python-Port)

Der IQR-Algorithmus aus My Price Log wird 1:1 nach Python portiert:

```python
def analyze_prices(
    prices: list[PriceEntry],
    sources: dict[int, PriceSource],
    price_age_settings: PriceAgeSettings,
    now: datetime,
) -> PriceAnalysis:
    """
    1. Für jeden Price: Loyalty-Adjustment → Inflation-Adjustment → Unit Price
    2. Filtere ANCIENT-Preise aus
    3. Wenn ≥3 aktuelle Preise: IQR-Klassifikation (GOOD/OK/BAD)
    4. Auto-Denominator für Unit-Price-Anzeige
    """
```

**Inflation-Adjustment-Formel (identisch zu MPL):**
```python
if age_days <= stale_threshold_days:
    return price  # keine Inflation für frische Preise
else:
    effective_age = age_days - stale_threshold_days
    annual_rate = 1 + (annual_inflation_percent / 100)
    return price * (annual_rate ** (effective_age / 365.25))
```

**IQR-Klassifikation:**
```python
k = 0.1  # Buffer-Faktor
Q1 = quantile(numerators, 0.25)
Q3 = quantile(numerators, 0.75)
good = Q1 * (1 - k)
bad = Q3 * (1 + k)
# < good → GOOD, ≤ bad → OK, > bad → BAD
```

---

## 7. UI-Integrationsstrategie

### 7.1 Navigation

Der Preislog wird als **neuer Tab im Household** integriert. Die bestehende Household-Tab-Navigation:

```
Household
├── Einkaufslisten (bestehend)
├── Rezepte (bestehend)
├── Planer (bestehend)
├── Ausgaben (bestehend)
├── Preise (NEU)     ← Preisvergleich
└── Karte (NEU)       ← Map-Pins
```

### 7.2 Screens (Flutter)

| Screen | Beschreibung | Vorbild |
|---|---|---|
| `PriceOverviewPage` | Überblick: Items + letzte Preise | MPL HomeScreen |
| `PriceComparePage` | Preisvergleichstabelle pro Item | MPL PriceComparisonCard |
| `PriceEntryPage` | Einzelpreis-Detailansicht | KitchenOwl ExpensePage |
| `PriceAddUpdatePage` | Preis erstellen/bearbeiten | KitchenOwl ExpenseAddUpdatePage |
| `PriceHistoryPage` | Preishistorie mit Diffs | MPL ViewPriceHistory |
| `PriceSourceListPage` | Shop-Verwaltung | KitchenOwl SettingsPage |
| `PriceSourceAddUpdatePage` | Shop erstellen/bearbeiten | Pattern: CategoryEdit |
| `PriceItemListPage` | Preis-Item-Verwaltung | KitchenOwl ItemPage |
| `PriceItemAddUpdatePage` | Preis-Item erstellen/bearbeiten | Pattern: ItemEdit |
| `MapPage` | Karte mit Pins | flutter_map |
| `MapPinAddUpdatePage` | Pin erstellen/bearbeiten | Pattern: Edit-Seite |
| `MapPinDetailPage` | Pin-Detail + Preise + Kommentare | KitchenOwl RecipePage |
| `CommentListWidget` | Kommentar-Liste (Widget, kein Screen) | Neues Widget |
| `CommentAddWidget` | Kommentar-Eingabe | Neues Widget |

### 7.3 Design-Prinzipien

- **KitchenOwl-Stil:** Material 3, Dynamic Colors, `CustomScrollView` + Slivers, `SliverImageAppBar`
- **Konsistente Patterns:** Cubit → State → BlocBuilder, Model → fromJson/toJson/copyWith
- **Kommentar-Widget** wird als wiederverwendbare Komponente gebaut und auf allen relevanten Seiten eingebunden
- **Preis-Judgement-Icons** folgen dem KitchenOwl-Icon-Stil (GOOD = grüner Check, BAD = roter Cancel, OK = gelber/gray Remove)

---

## 8. Map-Feature-Strategie

### 8.1 Technische Wahl: flutter_map + OpenStreetMap

- **flutter_map** (Pub: `flutter_map`) — Open-Source, kein API-Key, keine Kosten
- **OpenStreetMap** als Tile-Provider
- **Keine** Google Maps / MapBox Abhängigkeit
- Kompatibel mit Flutter Web, Android, iOS

Benötigte Abhängigkeiten (neu in `pubspec.yaml`):
```yaml
flutter_map: ^7.0.2       # OSM-basierte Karte
latlong2: ^0.9.1          # Koordinaten-Typen
```

### 8.2 Pin-Typen

| Typ | Beschreibung | Icon |
|---|---|---|
| **Shop-Pin** | Mit `price_source` verknüpft | Shop-Icon (Einkaufswagen) |
| **Allgemeiner Pin** | Keine Verknüpfung | Standard-Marker |

### 8.3 Interaktion

1. **Karte öffnen:** Household-Tab "Karte"
2. **Pin setzen:** Long-Press auf Karte → `MapPinAddUpdatePage`
3. **Pin antippen:** `MapPinDetailPage` mit:
   - Name, Beschreibung (Markdown)
   - Wenn Shop-Pin: Verknüpfte Preiseinträge (letzte N)
   - Kommentar-Liste + Kommentar-Eingabe
4. **Pin bearbeiten/löschen:** Via Detailseite (Admin-Rechte)

### 8.4 Clustering

Bei vielen Pins: serverseitiges Bounding-Box-Filtering. Kein clientseitiges Clustering in V1.

---

## 9. Kommentar-Modell-Strategie

### 9.1 Datenmodell

Polymorphe Kommentare über `entity_type` + `entity_id` (siehe 4.5).

### 9.2 Berechtigung

- Jedes Household-Mitglied kann Kommentare lesen
- Jedes Household-Mitglied kann Kommentare schreiben
- Jeder Nutzer kann nur seine eigenen Kommentare bearbeiten/löschen
- Household-Admins können alle Kommentare löschen

### 9.3 UI-Integration

Das Kommentar-Widget (`CommentListWidget`) wird auf folgenden Seiten eingebunden:

```
RecipePage           ← Kommentare zum Rezept
ExpensePage          ← Kommentare zur Ausgabe
PriceEntryPage       ← Kommentare zum Preiseintrag
PriceSourceDetailPage ← Kommentare zum Shop
MapPinDetailPage     ← Kommentare zum Pin
```

### 9.4 Echtzeit

Neue Kommentare werden via Socket.IO (`comment:add`) an alle Household-Mitglieder gepusht.

---

## 10. Einladungs- und Shared-Data-Strategie

Das bestehende KitchenOwl-Household-System wird 1:1 verwendet:

- **Household** = Gemeinsamer Datenraum
- **Einladung** = Bestehendes Invite-System
- **Rollen** = Owner, Admin, Member (bestehend)
- **Rechte** = `DbModelAuthorizeMixin` + `@authorize_household()`

Neue Entitäten (`price_source`, `price_item`, `price_entry`, `map_pin`, `comment`) erhalten alle `DbModelAuthorizeMixin` und sind damit automatisch Household-scoped.

**Keine Änderung** am bestehenden Auth-/Berechtigungssystem.

---

## 11. Authentifizierung und Echtzeit-Sync

**Bleibt unverändert:**
- JWT (Access + Refresh Token Rotation)
- OIDC (Google, Apple, Custom)
- Socket.IO WebSockets
- RabbitMQ für Multi-Instance (bestehend)

**Neu:**
- Socket.IO Events für Preislog + Kommentare (siehe 5.4)
- Keine neuen Auth-Flows

---

## 12. Migrationsstrategie

### 12.1 Neue Alembic-Migrationen

Reihenfolge (Abhängigkeiten):
1. `price_source` + `price_item` erstellen (unabhängig)
2. `price_entry` erstellen (FK → price_source, price_item)
3. `price_history` erstellen (FK → household, price_item, price_source)
4. `map_pin` erstellen (FK → household, price_source)
5. `comment` erstellen (FK → household, user)
6. `household.price_log_feature` hinzufügen (neue Spalte)

### 12.2 Keine Datenmigration

- **KitchenOwl:** Alle bestehenden Tabellen bleiben unverändert
- **My Price Log:** Keine automatische Migration von MPL-Daten (MPL ist Android-only, lokal). User können Preisdaten manuell in KitchenOwl eingeben.

### 12.3 Daten-Erhaltung

| Kategorie | Ansatz |
|---|---|
| Bestehende KitchenOwl-Daten | ✅ Unberührt (nur neue Tabellen/Spalten) |
| Bestehende MPL-Daten | Keine automatische Migration nötig |
| Bestehende Supabase-Daten | Nicht anwendbar (kein Supabase) |
| Neue Migrationen | Nur `CREATE TABLE` + `ALTER TABLE ADD COLUMN` |

---

## 13. Backup- und Rollback-Strategie

### 13.1 Vor Migration

```bash
# PostgreSQL
pg_dump kitchenowl > backup_$(date +%Y%m%d_%H%M%S).sql
# SQLite
cp instance/kitchenowl.db backup_$(date +%Y%m%d_%H%M%S).db
```

### 13.2 Rollback

Falls nötig:
```bash
# PostgreSQL
psql kitchenowl < backup_DATE.sql
# SQLite: DB-Datei wiederherstellen
cp backup_DATE.db instance/kitchenowl.db
```

### 13.3 Während Entwicklung

- Alle Änderungen sind in Alembic-Migrationen versioniert
- `flask db downgrade` rollt einzelne Migrationen zurück
- Git-Branch erlaubt kompletten Reset auf `main`

---

## 14. Git-Workflow

### Empfehlung: Feature-Branch vom `main`

```
main (KitchenOwl upstream)
  └── merge/my-price-log (Merge-Branch)
       ├── feature/price-log-backend     (Backend-Modelle + API)
       ├── feature/price-log-frontend    (Flutter-Screens + Cubits)
       ├── feature/comments              (Kommentar-System)
       ├── feature/map                   (Karte + Pins)
       └── feature/settings-integration  (Feature-Flags, Einstellungen)
```

**Commit-Strategie:**
- Ein Commit pro logischer Einheit
- Commit-Messages auf Englisch (KitchenOwl-Konvention)
- Kein `--amend` auf geteilten Branches
- Vor Merge: `./scripts/ci.sh` muss grün sein

---

## 15. Tests

### 15.1 Backend-Tests (pytest)

Neue Test-Dateien:
```
backend/tests/api/
  test_api_price_source.py    ← CRUD + Auth
  test_api_price_item.py      ← CRUD + Auth
  test_api_price_entry.py     ← CRUD + Analyse + History + Auth
  test_api_comment.py         ← CRUD + Polymorphie
  test_api_map_pin.py         ← CRUD + Bounding Box
  test_price_analysis.py      ← IQR-Algorithmus Unit-Tests
```

**Test-Muster** (folgt `test_api_expense.py`):
- Fixtures: `household`, `user`, `price_source`, `price_item`, `price_entry`
- Auth-Tests: 401 ohne Token, 403 für Nicht-Member
- CRUD: Create, Read, Update, Delete
- Edge Cases: Leere Felder, ungültige Werte, gelöschte Referenzen

### 15.2 Frontend-Tests (flutter_test)

Neue Test-Dateien:
```
kitchenowl/test/
  cubits/price_overview_cubit_test.dart
  cubits/price_entry_cubit_test.dart
  cubits/comment_cubit_test.dart
  cubits/map_pin_cubit_test.dart
  models/price_models_test.dart
  widgets/price_comparison_card_test.dart
```

### 15.3 CI-Integration

Die neuen Tests werden automatisch in die bestehenden GitHub-Actions-Workflows integriert:
- `pytest.yml` — pytest mit Coverage (Backend)
- `tests.yaml` — flutter analyze + flutter test (Frontend)

---

## 16. Build-Prozess

### 16.1 Bestehende Builds (unverändert)

```bash
# Backend
cd backend && uv run pytest
cd backend && uv run ruff format --check && uv run ruff check

# Frontend
cd kitchenowl && flutter analyze
cd kitchenowl && flutter test
```

### 16.2 Neue Abhängigkeiten

**Backend (`pyproject.toml`):** Keine neuen (alle nötigen Libs bereits vorhanden)

**Frontend (`pubspec.yaml`):**
```yaml
flutter_map: ^7.0.2
latlong2: ^0.9.1
```

### 16.3 Vollständiger CI-Check

```bash
./scripts/ci.sh  # Linux/macOS
.\scripts\ci.ps1  # Windows
```

---

## 17. Phased Implementation

### Phase A: Backend — Datenmodell + Basis-API
**Geschätzt: 3-4 Stunden**

1. `MeasurementUnit`-Enum in `backend/app/models/measurement_unit.py`
2. `PriceSource`-Modell + Controller
3. `PriceItem`-Modell + Controller
4. `PriceEntry`-Modell + Controller (CRUD, kein Analyse-Algorithmus)
5. `PriceHistory`-Modell
6. Alembic-Migrationen
7. Tests für alle neuen Endpunkte

### Phase B: Backend — Preisanalyse + Kommentare + Map-Pins
**Geschätzt: 2-3 Stunden**

8. `PriceAnalysis`-Service (IQR, Inflation, Loyalty) → Port von Kotlin
9. `/price-entry/analysis`-Endpoint
10. `Comment`-Modell + Controller
11. `MapPin`-Modell + Controller
12. Socket.IO Events für Preislog + Kommentare + Pins
13. Tests

### Phase C: Frontend — Datenmodelle + API-Service + Cubits
**Geschätzt: 3-4 Stunden**

14. Neue Flutter-Modelle (price_source, price_item, price_entry, comment, map_pin)
15. API-Service-Extensions
16. Cubits (PriceOverviewCubit, PriceEntryCubit, CommentCubit, MapPinCubit)
17. Widget-Tests

### Phase D: Frontend — Preislog-Screens
**Geschätzt: 4-5 Stunden**

18. `PriceSourceListPage` + `PriceSourceAddUpdatePage`
19. `PriceItemListPage` + `PriceItemAddUpdatePage`
20. `PriceOverviewPage` (Übersicht)
21. `PriceComparePage` (Vergleichstabelle mit GOOD/OK/BAD)
22. `PriceEntryPage` + `PriceAddUpdatePage`
23. `PriceHistoryPage` (Diff-Ansicht)
24. Navigation-Integration (neue Household-Tabs)

### Phase E: Frontend — Kommentar-System
**Geschätzt: 2 Stunden**

25. `CommentListWidget` (lesen + schreiben)
26. `CommentAddWidget` (Eingabe + Markdown-Vorschau)
27. Integration in RecipePage, ExpensePage, PriceEntryPage, PriceSourcePage, MapPinPage

### Phase F: Frontend — Map-Feature
**Geschätzt: 3-4 Stunden**

28. flutter_map + latlong2 zu pubspec.yaml hinzufügen
29. `MapPage` mit OSM-Tiles + Pins
30. `MapPinAddUpdatePage`
31. `MapPinDetailPage` (Pin-Details + verknüpfte Preise + Kommentare)
32. Long-Press zum Pin-Setzen
33. Bounding-Box-Filter

### Phase G: Integration + Household-Feature-Flags
**Geschätzt: 1-2 Stunden**

34. `household.price_log_feature`-Flag in Settings
35. Feature-Toggle in Household-UI
36. Integrationstests
37. Vollständiger CI-Durchlauf

---

## 18. Risiken und Gegenmaßnahmen

| Risiko | Eintrittsw. | Auswirkung | Gegenmaßnahme |
|---|---|---|---|
| **flutter_map Performance auf Web** | Mittel | Mittel | Lazy-Loading, Bounding-Box-Filter serverseitig |
| **IQR-Algorithmus Präzision** | Niedrig | Mittel | 1:1-Port mit identischen Tests |
| **Kommentar-Polymorphie komplex** | Niedrig | Niedrig | Einfaches entity_type+entity_id-Muster wie `report` |
| **Socket.IO Event-Überflutung** | Niedrig | Hoch | Events nur für Household-Room, wie bestehend |
| **Unit-System Komplexität** | Mittel | Mittel | Nur Metric + Imperial + US + Item, kein Live-Wechsel nötig |
| **MPL-Daten nicht migrierbar** | Niedrig | Niedrig | Manuelle Eingabe akzeptabel, später CSV-Import möglich |

---

## 19. Offene Fragen

1. **Währung pro Household:** Soll der Preislog die Household-Währung verwenden (wie Expenses)? Oder pro DataSet? **Empfehlung:** Household-Währung.

2. **Preislog-Feature-Flag:** Soll der Preislog per Default aktiviert sein für neue Households? **Empfehlung:** Default `True` für neue Households, `False` für bestehende (Opt-in).

3. **MPL Demo-Daten:** Sollen die Demo-Daten aus My Price Log als optionale Seed-Daten verfügbar sein? **Empfehlung:** In V1 weglassen, später als optionaler Import.

4. **CSV-Import für Preise?** Für Nutzer, die von MPL migrieren wollen. **Empfehlung:** V2-Feature.

---

## 20. Zusammenfassung: Was wird NICHT geändert?

- ✅ Keine Änderung an bestehenden KitchenOwl-Tabellen (außer `household.price_log_feature`)
- ✅ Keine Änderung am Auth-System
- ✅ Keine Änderung am Socket.IO-System
- ✅ Keine Änderung an Einkaufslisten, Rezepten, Planer, Expenses
- ✅ Keine Änderung an Export/Import
- ✅ Keine Löschung von bestehenden Features
- ✅ Keine neuen externen Dienste (außer OSM-Tiles, die kostenlos sind)
- ✅ Kein Supabase

---

## 21. Erfolgskriterien

Die Integration ist abgeschlossen, wenn:

1. ✅ Preislog (Items, Sources, Entries, History, Analyse) voll funktionsfähig
2. ✅ Kommentare auf Rezepten, Preiseinträgen, Shops, Map-Pins, Expenses
3. ✅ Karte mit Pins (OSM), Pin-Shop-Verknüpfung, Preise aus Pin abrufbar
4. ✅ Household-Berechtigungen funktionieren für alle neuen Features
5. ✅ Echtzeit-Sync via Socket.IO für Preisänderungen + Kommentare
6. ✅ `./scripts/ci.sh` / `.\scripts\ci.ps1` grün
7. ✅ Bestehende KitchenOwl-Features unverändert
8. ✅ Keine destruktiven Datenänderungen
9. ✅ UI folgt KitchenOwl-Design

---

## 22. Freigabe-Anfrage

Bitte bestätige folgende Entscheidungen, damit ich mit Phase 4 (Implementierung) beginnen kann:

1. **Flask-Backend bleibt, kein Supabase** — bestätigt
2. **OpenStreetMap via flutter_map** — bestätigt
3. **Bestehendes Berechtigungsmodell (Owner/Admin/Member)** — bestätigt
4. **Feature-Branch-Strategie** — wie oben beschrieben
5. **Preislog innerhalb Household, kein separates DataSet** — bitte bestätigen
6. **Währung pro Household** — bitte bestätigen oder Alternative nennen
7. **Feature-Flag `price_log_feature`** — Default `True` für neue, `False` für bestehende Households — bitte bestätigen
8. **Phasen-Reihenfolge A→G** wie oben — bitte bestätigen

Sobald du freigibst, beginne ich mit **Phase A: Backend-Datenmodell + Basis-API**.
