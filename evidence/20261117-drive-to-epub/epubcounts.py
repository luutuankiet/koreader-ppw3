"""Counts only for an EPUB: entries, sizes by kind, spine length, xhtml size. Never prints content."""
import sys, zipfile, re, collections
z = zipfile.ZipFile(sys.argv[1]); bad = z.testzip()
names = z.namelist(); kinds = collections.Counter(); sizes = collections.Counter()
for i in z.infolist():
    ext = i.filename.rsplit(".", 1)[-1].lower(); kinds[ext] += 1; sizes[ext] += i.file_size
opf = next(n for n in names if n.endswith(".opf")); o = z.read(opf).decode()
print({"zip_ok": bad is None, "entries": len(names), "by_ext": dict(kinds), "uncompressed_bytes_by_ext": dict(sizes),
       "spine_itemrefs": len(re.findall(r"<itemref\b", o)), "first_entry": names[0]})
