/*
 * MicroEmulator
 * Copyright (C) 2008 Bartek Teodorczyk <barteo@barteo.net>
 * Copyright (C) 2017-2018 Nikita Shakarun
 * <p>
 * It is licensed under the following two licenses as alternatives:
 * 1. GNU Lesser General Public License (the "LGPL") version 2.1 or any newer version
 * 2. Apache License (the "AL") Version 2.0
 * <p>
 * You may not use this file except in compliance with at least one of
 * the above two licenses.
 * <p>
 * You may obtain a copy of the LGPL at
 * http://www.gnu.org/licenses/old-licenses/lgpl-2.1.txt
 * <p>
 * You may obtain a copy of the AL at
 * http://www.apache.org/licenses/LICENSE-2.0
 * <p>
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the LGPL or the AL for the specific language governing permissions and
 * limitations.
 *
 * @version $Id$
 */
package javax.microedition.rms.impl;

import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.FileNotFoundException;
import java.io.IOException;
import java.util.Map;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.concurrent.ConcurrentHashMap;

import javax.microedition.rms.InvalidRecordIDException;
import javax.microedition.rms.RecordStore;
import javax.microedition.rms.RecordStoreException;
import javax.microedition.rms.RecordStoreNotFoundException;

public class AndroidRecordStoreManager implements RecordStoreManager {
	private final static String RECORD_STORE_HEADER_SUFFIX = ".rsh";

	private final static String RECORD_STORE_RECORD_SUFFIX = ".rsr";

	private final static Object NULL_STORE = new Object();

	private Map<String, Object> recordStores = null;

	// The save root is fixed for a MiniJVM session. Cache its RMS directory so
	// opening a store from a hot paint path does not call mkdirs()/exists() on
	// every open. Different roots remain isolated by the map key.
	private static final Map<String, File> DATA_DIR_CACHE = new ConcurrentHashMap<>();

	private static final int MAX_CLOSED_STORES = 16;
	private static final long MAX_CLOSED_STORE_BYTES = 256 * 1024L;
	private static final long MAX_CLOSED_CACHE_BYTES = 1024 * 1024L;
	private final LinkedHashMap<String, RecordStoreImpl.CacheSnapshot> closedStoreCache =
			new LinkedHashMap<>(16, 0.75f, true);
	private long closedStoreCacheBytes;

	synchronized void cacheClosedStore(RecordStoreImpl store) {
		String name = store.getRecordStoreName();
		if (recordStores == null || recordStores.get(name) != store || store.isOpen()) {
			store.clearCachedRecords();
			return;
		}
		RecordStoreImpl.CacheSnapshot snapshot = store.detachCacheSnapshot();
		long bytes = snapshot.bytes;
		synchronized (closedStoreCache) {
			RecordStoreImpl.CacheSnapshot previous = closedStoreCache.remove(name);
			if (previous != null) {
				closedStoreCacheBytes -= previous.bytes;
				previous.clear();
			}
			if (bytes > MAX_CLOSED_STORE_BYTES) {
				snapshot.clear();
				return;
			}
			closedStoreCache.put(name, snapshot);
			closedStoreCacheBytes += bytes;
			while (closedStoreCache.size() > MAX_CLOSED_STORES
					|| closedStoreCacheBytes > MAX_CLOSED_CACHE_BYTES) {
				Iterator<Map.Entry<String, RecordStoreImpl.CacheSnapshot>> it =
						closedStoreCache.entrySet().iterator();
				if (!it.hasNext()) break;
				RecordStoreImpl.CacheSnapshot evicted = it.next().getValue();
				it.remove();
				closedStoreCacheBytes -= evicted.bytes;
				evicted.clear();
			}
		}
	}

	private RecordStoreImpl.CacheSnapshot takeClosedStore(String name) {
		synchronized (closedStoreCache) {
			RecordStoreImpl.CacheSnapshot snapshot = closedStoreCache.remove(name);
			if (snapshot != null) closedStoreCacheBytes -= snapshot.bytes;
			return snapshot;
		}
	}

	private void evictClosedStore(String name) {
		synchronized (closedStoreCache) {
			RecordStoreImpl.CacheSnapshot evicted = closedStoreCache.remove(name);
			if (evicted != null) {
				closedStoreCacheBytes -= evicted.bytes;
				evicted.clear();
			}
		}
	}


	private static File getDataDir() {
		String root = System.getProperty("app.save.root");
		if (root == null) root = ".";
		File cached = DATA_DIR_CACHE.get(root);
		if (cached != null) return cached;
		File dir = new File(root + "/rms");
		dir.mkdirs();
		File raced = DATA_DIR_CACHE.putIfAbsent(root, dir);
		return raced == null ? dir : raced;
	}

	private static String sanitizeName(String name) {
		return name.replaceAll("[\\\\/:*?\"<>|]", "");
	}

	@Override
	public String getName() {
		return "Android record store";
	}

	private synchronized void initializeIfNecessary() {
		if (recordStores == null) {
			recordStores = new ConcurrentHashMap<>();
			String[] list = getDataDir().list();
			if (list != null) {
				for (String fileName : list) {
					if (fileName.endsWith(RECORD_STORE_HEADER_SUFFIX)) {
						recordStores.put(fileName.substring(0,
								fileName.length() - RECORD_STORE_HEADER_SUFFIX.length()), NULL_STORE);
					}
				}
			}
		}
	}

	@Override
	public synchronized void deleteRecordStore(String recordStoreName) throws RecordStoreException {
		initializeIfNecessary();

		recordStoreName = sanitizeName(recordStoreName);
		Object value = recordStores.get(recordStoreName);
		if (value == null) {
			throw new RecordStoreNotFoundException(recordStoreName);
		}
		if (value instanceof RecordStoreImpl && ((RecordStoreImpl) value).isOpen()) {
			throw new RecordStoreException();
		}
		evictClosedStore(recordStoreName);

		File dataDir = getDataDir();
		String prefix = recordStoreName + ".";
		String[] files = dataDir.list();
		if (files != null) {
			for (String name : files) {
				int dot = name.indexOf('.', prefix.length() + 1);
				if ((dot == -1 || dot == name.lastIndexOf('.')) && name.startsWith(prefix)) {
					//noinspection ResultOfMethodCallIgnored
					new File(dataDir, name).delete();
				}
			}
		}

		recordStores.remove(recordStoreName);
		RmsEventLog.note("DELETE_STORE", recordStoreName, -1, -1);
		System.out.println("[RMS] Store deleted");
	}

	@Override
	public synchronized RecordStore openRecordStore(String recordStoreName, boolean createIfNecessary)
			throws RecordStoreException {
		initializeIfNecessary();
		recordStoreName = sanitizeName(recordStoreName);

		RecordStoreImpl recordStoreImpl;
		Object value = recordStores.get(recordStoreName);
		if (value instanceof RecordStoreImpl && ((RecordStoreImpl) value).isOpen()) {
			((RecordStoreImpl) value).setOpen();
			RmsEventLog.note("OPEN", recordStoreName, -1, -1);
			return (RecordStoreImpl) value;
		}
		if (value instanceof RecordStoreImpl) {
			RecordStoreImpl.CacheSnapshot snapshot = takeClosedStore(recordStoreName);
			if (snapshot != null) {
				recordStoreImpl = new RecordStoreImpl(this, snapshot);
				recordStoreImpl.setOpen();
				recordStores.put(recordStoreName, recordStoreImpl);
				RmsEventLog.note("OPEN_CACHE", recordStoreName, -1, -1);
				return recordStoreImpl;
			}
		}

		boolean created = false;
		String headerName = getHeaderFileName(recordStoreName);
		File headerFile = new File(getDataDir(), headerName);
		try (DataInputStream dis = new DataInputStream(new FileInputStream(headerFile))) {
			recordStoreImpl = new RecordStoreImpl(this);
			recordStoreImpl.readHeader(dis);
			recordStoreImpl.setOpen();
		} catch (FileNotFoundException e) {
			if (!createIfNecessary) {
				throw new RecordStoreNotFoundException(recordStoreName);
			}
			recordStoreImpl = new RecordStoreImpl(this, recordStoreName);
			recordStoreImpl.setOpen();
			saveToDisk(recordStoreImpl, -1);
			created = true;
		} catch (IOException e) {
			// miniJVM's FileInputStream throws IOException (not FileNotFoundException)
			// when the file doesn't exist.  Check if the header file actually exists
			// to distinguish "file not found" from "truly broken header".
			if (headerFile.exists()) {
				// A broken existing header must never be rewritten with a new
				// empty store. Preserve save bytes for user recovery.
				RmsEventLog.note("READ_ERROR", recordStoreName, -1, -1);
				throw new RecordStoreException("RMS header unreadable; original save preserved");
			}
			if (!createIfNecessary) {
				throw new RecordStoreNotFoundException(recordStoreName);
			}
			recordStoreImpl = new RecordStoreImpl(this, recordStoreName);
			recordStoreImpl.setOpen();
			saveToDisk(recordStoreImpl, -1);
			created = true;
		}

		// Publish only after all persisted records were actually read.
		// If a record is corrupt, the caller receives a failure and must
		// never reopen a half-populated in-memory store as if it were valid.
		synchronized (recordStoreImpl.records) {
			File dataDir = getDataDir();
			String prefix = recordStoreName + ".";
			String[] files = dataDir.list();
			if (files != null) {
				for (String name : files) {
					if (name.startsWith(prefix) && name.endsWith(RECORD_STORE_RECORD_SUFFIX)) {
						File file = new File(dataDir, name);
						try (DataInputStream dis = new DataInputStream(new FileInputStream(file))) {
							recordStoreImpl.readRecord(dis);
						} catch (IOException e) {
							// No fake zero-byte records. Keep the original disk data
							// unchanged; report an actual RMS failure to the MIDlet.
							RmsEventLog.note("READ_ERROR", recordStoreName, -1, -1);
							throw new RecordStoreException("RMS record unreadable; original save preserved");
						}
					}
				}
			}

		}

		recordStores.put(recordStoreName, recordStoreImpl);
		RmsEventLog.note(created ? "CREATE" : "OPEN", recordStoreName, -1, -1);
		System.out.println("[RMS] Store opened");
		return recordStoreImpl;
	}

	@Override
	public String[] listRecordStores() {
		initializeIfNecessary();

		String[] result = recordStores.keySet().toArray(new String[0]);

		if (result.length > 0) {
			return result;
		} else {
			return null;
		}
	}

	@Override
	public void deleteRecord(RecordStoreImpl recordStoreImpl, int recordId)
			throws RecordStoreException {
		deleteFromDisk(recordStoreImpl, recordId);
	}

	@Override
	public void loadRecord(RecordStoreImpl recordStoreImpl, int recordId)
			throws RecordStoreException {
		String recordName = getRecordFileName(recordStoreImpl.getName(), recordId);
		try (DataInputStream dis = new DataInputStream(new FileInputStream(new File(getDataDir(), recordName)))) {
			recordStoreImpl.readRecord(dis);
		} catch (FileNotFoundException e) {
			throw new InvalidRecordIDException();
		} catch (IOException e) {
			RmsEventLog.note("READ_ERROR", recordStoreImpl.getName(), recordId, -1);
			throw new RecordStoreException("RMS record read failed; original save preserved");
		}
	}

	@Override
	public void saveRecord(RecordStoreImpl recordStoreImpl, int recordId)
			throws RecordStoreException {
		saveToDisk(recordStoreImpl, recordId);
	}

	private synchronized void deleteFromDisk(RecordStoreImpl recordStore, int recordId)
			throws RecordStoreException {
		String headerName = getHeaderFileName(recordStore.getName());
		try (DataOutputStream dos = new DataOutputStream(new FileOutputStream(new File(getDataDir(), headerName)))) {
			recordStore.writeHeader(dos);
		} catch (IOException e) {
			System.out.println("RecordStore.saveToDisk: ERROR writing object to " + headerName + ": " + e.getMessage());
			throw new RecordStoreException(e.getMessage());
		}

		File target = new File(getDataDir(), getRecordFileName(recordStore.getName(), recordId));
		if (target.exists() && !target.delete()) {
			RmsEventLog.note("DELETE_ERROR", recordStore.getName(), recordId, -1);
			throw new RecordStoreException("RMS delete failed; record file preserved");
		}
		RmsEventLog.note("DELETE_RECORD", recordStore.getName(), recordId, -1);
	}

	/**
	 * @param recordId -1 for storing only header
	 */
	private synchronized void saveToDisk(RecordStoreImpl recordStore, int recordId)
			throws RecordStoreException {
		String headerName = getHeaderFileName(recordStore.getName());
		try (DataOutputStream dos = new DataOutputStream(new FileOutputStream(new File(getDataDir(), headerName)))) {
			recordStore.writeHeader(dos);
		} catch (IOException e) {
			RmsEventLog.note("SAVE_ERROR", recordStore.getName(), -1, -1);
			throw new RecordStoreException("RMS header write failed");
		}

		if (recordId != -1) {
			String recordName = getRecordFileName(recordStore.getName(), recordId);
			try (DataOutputStream dos = new DataOutputStream(new FileOutputStream(new File(getDataDir(), recordName)))) {
				recordStore.writeRecord(dos, recordId);
			} catch (IOException e) {
				RmsEventLog.note("SAVE_ERROR", recordStore.getName(), recordId, -1);
				throw new RecordStoreException("RMS record write failed");
			}
			byte[] data = recordStore.records.get(recordId);
			RmsEventLog.note("SAVE", recordStore.getName(), recordId,
				data == null ? -1 : data.length);
		}
	}

	@Override
	public int getSizeAvailable(RecordStoreImpl recordStoreImpl) {
		// TODO should return free space on device
		return 1024 * 1024;
	}

	private String getHeaderFileName(String recordStoreName) {
		return recordStoreName + RECORD_STORE_HEADER_SUFFIX;
	}

	private String getRecordFileName(String recordStoreName, int recordId) {
		return recordStoreName + "." + recordId + RECORD_STORE_RECORD_SUFFIX;
	}
}
