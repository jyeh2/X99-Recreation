# X99 ReBAR BIOS flash (2026-10-02)

Huananzhi X99-BD4, stock BIOS 5.11 (11/01/2020).

- `patched_image_fixed.rom`: the full 16 MB SPI image with the `ReBarDxe` DXE driver inserted
  (see `Screenshot 2026-10-02 051944.png`). This is the image that was flashed.
- `bench/`: CMP 40HX numbers before and after the unlock (`baseline_gen1.txt`,
  `after_unlock_gen2.txt`), the V100 VFIO VM run, and the pooled llama.cpp RPC run.
  `flops.cu` and `bw.cu` are the same files as `roles/benchmarks/files/`.
- Photos and screenshots: from the flashing session and the B580 / CMP checks around it.
  EXIF was stripped from the photos.
