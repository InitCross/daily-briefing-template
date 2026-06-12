# Daily Briefing Bot (Team Template)

บอทเลขาส่วนตัวบน **GitHub Actions** — ดึงงาน + PR ของคุณจาก Azure DevOps แล้วสรุปเป็น briefing ภาษาไทยส่งเข้า Telegram

- **ทุกเช้า จ–ศ 08:00** (เวลาไทย) — งานในมือ + PR ที่ต้องสนใจ + คำแนะนำ
- **อาทิตย์ 22:00** — สรุปงานที่ปิดทั้งสัปดาห์

> เวอร์ชันนี้ **ไม่มีปฏิทิน** (ตัดออกเพื่อ setup ง่าย) — มีแค่งาน + PR จาก Azure DevOps

---

## วิธีใช้ (setup ~10 นาที, ทำเองคนเดียวได้หมด)

### 0. สร้าง repo ของตัวเอง
กดปุ่ม **"Use this template" → "Create a new repository"** บนหน้า repo นี้ → ได้ copy เป็นของตัวเอง (แนะนำตั้งเป็น **Private**)

### 1. เตรียม credential 3 อย่าง

#### 🔹 Azure DevOps PAT
1. ไปที่ https://dev.azure.com/infogrammer/_usersSettings/tokens
2. **+ New Token** → scope: **Work Items (Read)** + **Code (Read)** → Create
3. copy string เก็บไว้ (เห็นครั้งเดียว)

> WIQL ใช้ `@Me` → ดึงเฉพาะงาน/PR ของเจ้าของ PAT อัตโนมัติ

#### 🔹 Telegram bot ของตัวเอง
1. ทัก **@BotFather** → `/newbot` → ตั้งชื่อ + username → ได้ **bot token**
2. กด **Start** บอทที่เพิ่งสร้าง (ให้มันส่งหาเราได้)
3. หา **chat_id** → ทัก **@userinfobot** → เอาเลข `Id` ที่มันตอบ (chat 1:1 → chat_id = user id)

#### 🔹 Gemini API key (ของตัวเอง — สำคัญ)
1. ไปที่ https://aistudio.google.com/apikey → **Create API key** (ฟรี)
2. copy เก็บไว้

> ⚠️ **อย่าแชร์ key กับเพื่อน** — free tier จำกัด **20 requests/วัน ต่อ key** ถ้าแชร์กันจะหารโควต้ากัน (บอทใช้ ~1-2/วัน → key ของตัวเองเหลือเฟือ)

### 2. ใส่ค่าใน repo ของตัวเอง

ไปที่ repo → **Settings → Secrets and variables → Actions**

**Tab "Secrets"** → New repository secret (4 ตัว):
| Name | Value |
|------|-------|
| `ADO_PAT` | PAT จากข้อ 1 |
| `TELEGRAM_BOT_TOKEN` | token จาก BotFather |
| `TELEGRAM_CHAT_ID` | เลขจาก @userinfobot |
| `GEMINI_API_KEY` | key จาก AI Studio |

**Tab "Variables"** → New repository variable (1 ตัว):
| Name | Value |
|------|-------|
| `OWNER_NAME` | ชื่อคุณ (ใช้ทักทาย เช่น "Pan", "Biw") |

### 3. เปิด Actions + ทดสอบ
1. ไปที่ tab **Actions** → ถ้าขึ้น "Workflows aren't being run" ให้กด **enable**
2. เลือก **Daily Briefing** → **Run workflow** → รอ ~20 วิ → เช็ค Telegram
3. ถ้าได้ briefing เข้าแชท = เสร็จ ✅ (จากนี้ cron จะรันเองทุกเช้า จ–ศ)

---

## ปรับแต่ง (optional)

- **เวลา/วันที่รัน:** แก้ `cron` ใน `.github/workflows/briefing.yml` (เป็น UTC — `0 1 * * 1-5` = 08:00 ไทย จ–ศ)
- **รูปแบบ/โทน briefing:** แก้ `prompts/briefing.md` (daily) หรือ `prompts/recap.md` (weekly)
- **เปลี่ยน model:** ตั้ง env `GEMINI_MODEL` (default `gemini-3.5-flash`)

---

## โครงสร้าง (how it works)

```
GitHub Actions cron
  → fetch-data.sh        : Azure DevOps REST (PAT) → data.json
  → generate-briefing.sh : Gemini API → briefing.html
  → send-telegram.sh     : Telegram Bot API
```
pure bash + curl + jq + 1 Gemini API call — ไม่มี server ต้องดูแล, รันบน GitHub Actions free tier

| ไฟล์ | หน้าที่ |
|------|--------|
| `scripts/fetch-data.sh` | ดึงงาน + PR (daily) |
| `scripts/fetch-recap-data.sh` | ดึงงานที่ปิด + PR merged (weekly) |
| `scripts/generate-briefing.sh` | เรียก Gemini สรุปเป็น HTML |
| `scripts/send-telegram.sh` | ส่ง Telegram (ตัด/แบ่งข้อความยาวอัตโนมัติ) |
| `prompts/*.md` | system prompt กำหนดรูปแบบ output |

---

## Maintenance

- **PAT หมดอายุ:** สร้างใหม่ใน Azure DevOps → update secret `ADO_PAT`
- **Gemini key:** rotate ที่ https://aistudio.google.com/apikey
- **ดู log/debug:** tab Actions → run ที่ fail จะ upload `data.json` + `briefing.html` เป็น artifact ให้
