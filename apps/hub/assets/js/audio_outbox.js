// Issue #936 (C): Durable Audio-Outbox auf IndexedDB.
//
// Jeder aufgenommene Audio-Chunk wird ZUERST hier persistiert, dann gesendet und
// erst nach bestätigtem Empfang (delivered:true) wieder gelöscht. Damit überlebt
// die Aufnahme einen Browser↔Hub-Abriss, einen Tab-Reload und einen Crash — auf
// gesunder Leitung bleibt der Store quasi leer (persist → send → ack → delete in
// ~1 s).
//
// FIFO-Ordnung über einen autoIncrement-Key (WebM/Opus muss in Reihenfolge
// angehängt werden). KEIN poison-skip: ein Chunk bleibt liegen, bis er zugestellt
// ist — ein „nicht zugestellt" ist im aktuellen Protokoll immer transient (kein
// Halter / Socket weg, siehe #935/D0), nie ein server-abgelehnter Chunk. Eine
// echte Poison-Erkennung (einzelnen Chunk überspringen statt die Session zu
// blockieren) braucht ein Server-Reject-Signal → Phase D (#938). Bis dahin ist
// „Head-of-Line" während eines Ausfalls das GEWOLLTE Verhalten: alles wird
// durabel gepuffert und in Reihenfolge nachgeschickt, nichts geht verloren.

const DB_NAME = "lore_audio_outbox";
const STORE = "chunks";
const DB_VERSION = 1;

export class AudioOutbox {
  constructor() {
    this._db = null;
  }

  _open() {
    if (this._db) return Promise.resolve(this._db);

    return new Promise((resolve, reject) => {
      const req = indexedDB.open(DB_NAME, DB_VERSION);

      req.onupgradeneeded = () => {
        const db = req.result;
        if (!db.objectStoreNames.contains(STORE)) {
          // autoIncrement-Key = strikte Insertion-/FIFO-Ordnung.
          db.createObjectStore(STORE, { keyPath: "key", autoIncrement: true });
        }
      };

      req.onsuccess = () => {
        this._db = req.result;
        resolve(this._db);
      };
      req.onerror = () => reject(req.error);
    });
  }

  // record: { session_id, instance_id, seq, mic_mode, chunk }. Wirft bei
  // QuotaExceededError (Storage voll / langer Ausfall) → Aufrufer droppt + retry.
  async enqueue(record) {
    const db = await this._open();
    return new Promise((resolve, reject) => {
      const tx = db.transaction(STORE, "readwrite");
      tx.objectStore(STORE).add(record);
      tx.oncomplete = () => resolve(true);
      tx.onerror = () => reject(tx.error);
      tx.onabort = () => reject(tx.error);
    });
  }

  async peekOldest() {
    const db = await this._open();
    return new Promise((resolve, reject) => {
      const tx = db.transaction(STORE, "readonly");
      const req = tx.objectStore(STORE).openCursor();
      req.onsuccess = () => resolve(req.result ? req.result.value : null);
      req.onerror = () => reject(req.error);
    });
  }

  async delete(key) {
    const db = await this._open();
    return new Promise((resolve, reject) => {
      const tx = db.transaction(STORE, "readwrite");
      tx.objectStore(STORE).delete(key);
      tx.oncomplete = () => resolve(true);
      tx.onerror = () => reject(tx.error);
    });
  }

  async dropOldest() {
    const oldest = await this.peekOldest();
    if (oldest) await this.delete(oldest.key);
    return oldest;
  }

  async count() {
    const db = await this._open();
    return new Promise((resolve, reject) => {
      const tx = db.transaction(STORE, "readonly");
      const req = tx.objectStore(STORE).count();
      req.onsuccess = () => resolve(req.result);
      req.onerror = () => reject(req.error);
    });
  }

  // Alle Records in FIFO-Reihenfolge (autoIncrement-Key). Issue #938: der Pump
  // iteriert darüber und überspringt bereits gesendete (in-flight) Chunks.
  async list() {
    const db = await this._open();
    return new Promise((resolve, reject) => {
      const tx = db.transaction(STORE, "readonly");
      const req = tx.objectStore(STORE).getAll();
      req.onsuccess = () => resolve(req.result || []);
      req.onerror = () => reject(req.error);
    });
  }

  // Issue #938 (D): Löschen per Chunk-Identität {instance_id, seq} — der Worker
  // ackt nach dem Plattenschreiben genau diese Identität (nicht den IndexedDB-Key).
  // Scan (der Store ist klein — auf gesunder Leitung ~leer).
  async deleteByChunkId(instanceId, seq) {
    const db = await this._open();
    return new Promise((resolve, reject) => {
      const tx = db.transaction(STORE, "readwrite");
      const req = tx.objectStore(STORE).openCursor();
      req.onsuccess = () => {
        const cur = req.result;
        if (!cur) {
          resolve(false);
          return;
        }
        const v = cur.value;
        if (v.instance_id === instanceId && v.seq === seq) {
          cur.delete();
          resolve(true);
          return;
        }
        cur.continue();
      };
      req.onerror = () => reject(req.error);
    });
  }
}
