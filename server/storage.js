const fs = require('fs');
const configModule = require('./config');
const config = configModule.config;
const b2Config = configModule.b2 || {};
const r2Config = configModule.r2 || {};

let supabase = null;
let MEDIA_BUCKET = 'sos-media';
try {
  const sb = require('./supabase');
  supabase = sb.supabase;
  MEDIA_BUCKET = sb.MEDIA_BUCKET || MEDIA_BUCKET;
} catch (_) {
  supabase = null;
}

let S3Client = null;
let PutObjectCommand = null;
let GetObjectCommand = null;
let DeleteObjectsCommand = null;
let getSignedUrl = null;
try {
  const aws = require('@aws-sdk/client-s3');
  S3Client = aws.S3Client;
  PutObjectCommand = aws.PutObjectCommand;
  GetObjectCommand = aws.GetObjectCommand;
  DeleteObjectsCommand = aws.DeleteObjectsCommand;
} catch (_) {
  S3Client = null;
}
try {
  ({ getSignedUrl } = require('@aws-sdk/s3-request-presigner'));
} catch (_) {
  getSignedUrl = null;
}

function normalizeBaseUrl(value) {
  return String(value || '').replace(/\/+$/, '');
}

function joinUrl(base, key) {
  return `${normalizeBaseUrl(base)}/${String(key).replace(/^\/+/, '')}`;
}

function regionFromEndpoint(endpoint) {
  try {
    const host = new URL(endpoint).hostname;
    const match = /^s3[.-]([a-z0-9-]+)\.backblazeb2\.com$/i.exec(host);
    return match ? match[1] : '';
  } catch (_) {
    return '';
  }
}

function b2Reference(bucket, key) {
  return `b2://${bucket}/${key}`;
}

function parseB2Reference(value) {
  if (typeof value !== 'string' || !value.startsWith('b2://')) return null;
  const rest = value.slice('b2://'.length);
  const slash = rest.indexOf('/');
  if (slash <= 0 || slash === rest.length - 1) return null;
  return { bucket: rest.slice(0, slash), key: rest.slice(slash + 1) };
}

function keyFromReference(value) {
  if (!value) return '';
  if (typeof value !== 'string') return '';
  if (value.startsWith('b2://')) {
    const parsed = parseB2Reference(value);
    return parsed ? parsed.key : '';
  }
  try {
    const parsed = new URL(value);
    const parts = parsed.pathname.split('/').filter(Boolean);
    return parts.length ? decodeURIComponent(parts[parts.length - 1]) : '';
  } catch (_) {
    const clean = value.split('?')[0];
    return clean.split('/').filter(Boolean).pop() || '';
  }
}

let b2Client = null;
const b2Region = b2Config.region || regionFromEndpoint(b2Config.endpoint);

if (S3Client && b2Config.keyId && b2Config.applicationKey && b2Config.bucket && (b2Config.endpoint || b2Region)) {
  const endpoint = b2Config.endpoint || `https://s3.${b2Region}.backblazeb2.com`;
  b2Client = new S3Client({
    region: b2Region || regionFromEndpoint(endpoint) || 'us-east-1',
    endpoint,
    credentials: {
      accessKeyId: b2Config.keyId,
      secretAccessKey: b2Config.applicationKey
    },
    forcePathStyle: true
  });
  console.log(`[storage] Backblaze B2 configured (bucket: ${b2Config.bucket}, endpoint: ${endpoint})`);
} else if (b2Config.keyId || b2Config.applicationKey || b2Config.region || b2Config.endpoint) {
  console.warn('[storage] Backblaze B2 partially configured - falling back to R2/Supabase if available');
}

let r2 = null;

if (S3Client && r2Config.accountId && r2Config.accessKeyId && r2Config.secretAccessKey && r2Config.bucket) {
  const endpoint = r2Config.endpoint || `https://${r2Config.accountId}.r2.cloudflarestorage.com`;
  r2 = new S3Client({
    region: 'auto',
    endpoint,
    credentials: {
      accessKeyId: r2Config.accessKeyId,
      secretAccessKey: r2Config.secretAccessKey
    },
    forcePathStyle: true
  });
  console.log(`[storage] Cloudflare R2 configured (bucket: ${r2Config.bucket})`);
} else if (r2Config.accountId || r2Config.accessKeyId || r2Config.secretAccessKey) {
  console.warn('[storage] R2 partially configured - falling back to Supabase if available');
}

if (!b2Client && !r2 && supabase) {
  console.log(`[storage] Supabase storage configured (bucket: ${MEDIA_BUCKET})`);
}
if (!b2Client && !r2 && !supabase) {
  console.warn('[storage] No object storage configured - media uploads will be disabled');
}

function isConfigured() {
  return !!b2Client || !!r2 || !!supabase;
}

function configuredBackend() {
  if (b2Client) return 'b2';
  if (r2) return 'r2';
  if (supabase) return 'supabase';
  return null;
}

async function uploadToB2(file, key) {
  try {
    const body = fs.createReadStream(file.path);
    await b2Client.send(new PutObjectCommand({
      Bucket: b2Config.bucket,
      Key: key,
      Body: body,
      ContentType: file.mimetype,
      ContentLength: file.size || undefined
    }));

    // A public bucket can expose a stable public URL. For a private bucket
    // (recommended) persist a b2:// reference and sign it when the API serves
    // the case, so evidence never becomes world-readable.
    if (b2Config.publicBaseUrl) return joinUrl(b2Config.publicBaseUrl, key);
    return b2Reference(b2Config.bucket, key);
  } catch (err) {
    console.error('[storage] B2 upload failed:', err && err.message ? err.message : err);
    return null;
  }
}

async function uploadToR2(file, key) {
  try {
    const body = fs.createReadStream(file.path);
    await r2.send(new PutObjectCommand({
      Bucket: r2Config.bucket,
      Key: key,
      Body: body,
      ContentType: file.mimetype,
      ContentLength: file.size || undefined
    }));

    const base = normalizeBaseUrl(r2Config.publicBaseUrl);
    if (!base) {
      console.error(
        '[storage] R2_PUBLIC_BASE_URL is not set; upload succeeded but no public URL was returned'
      );
      return null;
    }
    return joinUrl(base, key);
  } catch (err) {
    console.error('[storage] R2 upload failed:', err && err.message ? err.message : err);
    return null;
  }
}

async function upload(file, key) {
  if (!file) return null;

  if (b2Client) return uploadToB2(file, key);
  if (r2) return uploadToR2(file, key);

  if (supabase) {
    try {
      const { error } = await supabase.storage
        .from(MEDIA_BUCKET)
        .upload(key, fs.createReadStream(file.path), {
          contentType: file.mimetype,
          upsert: false,
          duplex: (file.size || 0) > 0 ? 'half' : undefined,
        });
      if (error) {
        console.error('[storage] Supabase upload failed:', error.message || error);
        return null;
      }
      const { data } = supabase.storage.from(MEDIA_BUCKET).getPublicUrl(key);
      return data ? data.publicUrl : null;
    } catch (err) {
      console.error('[storage] Supabase upload threw:', err && err.message ? err.message : err);
      return null;
    }
  }

  return null;
}

/**
 * Turn a stored media reference into a URL the browser/mobile client can open.
 * Legacy http(s) URLs pass through unchanged. Private B2 objects become
 * short-lived presigned URLs.
 */
async function resolveUrl(reference, expiresInSeconds = 3600) {
  if (!reference) return null;
  if (typeof reference !== 'string') return null;

  if (!reference.startsWith('b2://')) return reference;

  const parsed = parseB2Reference(reference);
  if (!parsed) return null;

  if (b2Config.publicBaseUrl) {
    return joinUrl(b2Config.publicBaseUrl, parsed.key);
  }

  if (!b2Client || !getSignedUrl || !GetObjectCommand) {
    console.error('[storage] B2 private URL requested but the S3 presigner is unavailable');
    return null;
  }

  const ttl = Math.min(Math.max(Number(expiresInSeconds) || 3600, 60), 7 * 24 * 60 * 60);
  try {
    return await getSignedUrl(
      b2Client,
      new GetObjectCommand({ Bucket: parsed.bucket, Key: parsed.key }),
      { expiresIn: ttl }
    );
  } catch (err) {
    console.error('[storage] B2 signing failed:', err && err.message ? err.message : err);
    return null;
  }
}

async function remove(keys) {
  const list = Array.isArray(keys) ? keys.filter(Boolean) : (keys ? [keys] : []);
  const objectKeys = [...new Set(list.map(keyFromReference).filter(Boolean))];
  if (objectKeys.length === 0) return;

  if (b2Client) {
    try {
      await b2Client.send(new DeleteObjectsCommand({
        Bucket: b2Config.bucket,
        Delete: { Objects: objectKeys.map((Key) => ({ Key })) }
      }));
    } catch (err) {
      console.error('[storage] B2 delete failed:', err && err.message ? err.message : err);
    }
    return;
  }

  if (r2) {
    try {
      await r2.send(new DeleteObjectsCommand({
        Bucket: r2Config.bucket,
        Delete: { Objects: objectKeys.map((Key) => ({ Key })) }
      }));
    } catch (err) {
      console.error('[storage] R2 delete failed:', err && err.message ? err.message : err);
    }
    return;
  }

  if (supabase) {
    try {
      await supabase.storage.from(MEDIA_BUCKET).remove(objectKeys);
    } catch (err) {
      console.error('[storage] Supabase delete failed:', err && err.message ? err.message : err);
    }
  }
}

module.exports = {
  isConfigured,
  configuredBackend,
  upload,
  resolveUrl,
  remove,
  keyFromReference,
  MEDIA_BUCKET,
  b2Bucket: b2Config.bucket || null,
  r2Bucket: r2Config.bucket || null,
};
