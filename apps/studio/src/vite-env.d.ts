/// <reference types="vite/client" />

interface FileSystemDirectoryHandle {
  values(): AsyncIterableIterator<FileSystemHandle>;
}

interface Window {
  showDirectoryPicker?: (options?: {
    mode?: 'read' | 'readwrite';
  }) => Promise<FileSystemDirectoryHandle>;
}
