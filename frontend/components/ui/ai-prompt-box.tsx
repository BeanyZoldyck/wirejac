"use client";

import * as React from "react";
import { Tooltip, TooltipContent, TooltipProvider, TooltipTrigger } from "@radix-ui/react-tooltip";
import * as DialogPrimitive from "@radix-ui/react-dialog";
import { X, ArrowUp, Paperclip, Square, Mic, Globe, BrainCog, FolderCode } from "lucide-react";
import { motion, AnimatePresence } from "framer-motion";
import { clsx, type ClassValue } from "clsx";
import { twMerge } from "tailwind-merge";

// Utility function for className merging (self-contained; do not import the Jac cn util)
export function cn(...inputs: ClassValue[]): string {
  return twMerge(clsx(inputs));
}

// Themed scrollbar styles (light minimalist theme — uses semantic border color)
const scrollbarStyles = `
  .promptbox-scroll::-webkit-scrollbar { width: 6px; }
  .promptbox-scroll::-webkit-scrollbar-track { background: transparent; }
  .promptbox-scroll::-webkit-scrollbar-thumb {
    background-color: var(--border, currentColor);
    border-radius: 3px;
  }
  .promptbox-scroll { scrollbar-width: thin; scrollbar-color: var(--border, currentColor) transparent; }
`;

if (typeof document !== "undefined" && !document.getElementById("promptbox-scrollbar-styles")) {
  const styleElement = document.createElement("style");
  styleElement.id = "promptbox-scrollbar-styles";
  styleElement.innerHTML = scrollbarStyles;
  document.head.appendChild(styleElement);
}

// Textarea Component
interface TextareaProps extends React.TextareaHTMLAttributes<HTMLTextAreaElement> {
  showRing?: boolean;
}
const Textarea = React.forwardRef<HTMLTextAreaElement, TextareaProps>(
  ({ className, showRing = true, ...props }, ref) => {
    const [isFocused, setIsFocused] = React.useState(false);
    return (
      <div className="relative">
        <textarea
          className={cn(
            "flex w-full rounded-md border-none bg-transparent px-3 py-2 text-sm text-foreground placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-0 disabled:cursor-not-allowed disabled:opacity-50",
            className
          )}
          ref={ref}
          onFocus={() => setIsFocused(true)}
          onBlur={() => setIsFocused(false)}
          {...props}
        />
        {showRing && isFocused && (
          <motion.span
            className="absolute inset-0 rounded-md pointer-events-none ring-2 ring-offset-0 ring-ring/50"
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            transition={{ duration: 0.2 }}
          />
        )}
      </div>
    );
  }
);
Textarea.displayName = "Textarea";

// Dialog Components
const Dialog = DialogPrimitive.Root;
const DialogTrigger = DialogPrimitive.Trigger;
const DialogPortal = DialogPrimitive.Portal;
const DialogClose = DialogPrimitive.Close;

const DialogOverlay = React.forwardRef<
  React.ElementRef<typeof DialogPrimitive.Overlay>,
  React.ComponentPropsWithoutRef<typeof DialogPrimitive.Overlay>
>(({ className, ...props }, ref) => (
  <DialogPrimitive.Overlay
    ref={ref}
    className={cn(
      "fixed inset-0 z-50 bg-foreground/40 backdrop-blur-sm data-[state=open]:animate-in data-[state=closed]:animate-out data-[state=closed]:fade-out-0 data-[state=open]:fade-in-0",
      className
    )}
    {...props}
  />
));
DialogOverlay.displayName = DialogPrimitive.Overlay.displayName;

const DialogContent = React.forwardRef<
  React.ElementRef<typeof DialogPrimitive.Content>,
  React.ComponentPropsWithoutRef<typeof DialogPrimitive.Content>
>(({ className, children, ...props }, ref) => (
  <DialogPortal>
    <DialogOverlay />
    <DialogPrimitive.Content
      ref={ref}
      className={cn(
        "fixed left-[50%] top-[50%] z-50 grid w-full max-w-lg translate-x-[-50%] translate-y-[-50%] gap-4 border border-border bg-card p-6 shadow-lg duration-200 data-[state=open]:animate-in data-[state=closed]:animate-out data-[state=closed]:fade-out-0 data-[state=open]:fade-in-0 rounded-2xl",
        className
      )}
      {...props}
    >
      {children}
    </DialogPrimitive.Content>
  </DialogPortal>
));
DialogContent.displayName = DialogPrimitive.Content.displayName;

const DialogTitle = React.forwardRef<
  React.ElementRef<typeof DialogPrimitive.Title>,
  React.ComponentPropsWithoutRef<typeof DialogPrimitive.Title>
>(({ className, ...props }, ref) => (
  <DialogPrimitive.Title
    ref={ref}
    className={cn("text-lg font-semibold leading-none tracking-tight text-foreground", className)}
    {...props}
  />
));
DialogTitle.displayName = DialogPrimitive.Title.displayName;

// Button Component
const buttonVariants = (
  variant: "default" | "outline" | "ghost" = "default",
  size: "default" | "sm" | "lg" | "icon" = "default"
) => {
  const base =
    "inline-flex items-center justify-center gap-2 whitespace-nowrap rounded-md text-sm font-medium transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring/50 disabled:pointer-events-none disabled:opacity-50";
  const variants = {
    default: "bg-primary text-primary-foreground hover:bg-primary/90",
    outline: "border border-border bg-background hover:bg-accent hover:text-accent-foreground",
    ghost: "hover:bg-accent hover:text-accent-foreground",
  };
  const sizes = {
    default: "h-10 px-4 py-2",
    sm: "h-8 px-3 text-xs",
    lg: "h-11 px-8",
    icon: "h-10 w-10",
  };
  return cn(base, variants[variant], sizes[size]);
};

interface ButtonProps extends React.ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: "default" | "outline" | "ghost";
  size?: "default" | "sm" | "lg" | "icon";
}
const Button = React.forwardRef<HTMLButtonElement, ButtonProps>(
  ({ className, variant = "default", size = "default", ...props }, ref) => (
    <button className={cn(buttonVariants(variant, size), className)} ref={ref} {...props} />
  )
);
Button.displayName = "Button";

// VoiceRecorder Component
interface VoiceRecorderProps {
  isRecording: boolean;
  onStartRecording: () => void;
  onStopRecording: (duration: number) => void;
  visualizerBars?: number;
}
const VoiceRecorder: React.FC<VoiceRecorderProps> = ({
  isRecording,
  onStartRecording,
  onStopRecording,
  visualizerBars = 32,
}) => {
  const [time, setTime] = React.useState(0);
  const timerRef = React.useRef<ReturnType<typeof setInterval> | null>(null);

  React.useEffect(() => {
    if (isRecording) {
      onStartRecording();
      timerRef.current = setInterval(() => setTime((t) => t + 1), 1000);
    } else {
      if (timerRef.current) clearInterval(timerRef.current);
      onStopRecording(time);
      setTime(0);
    }
    return () => {
      if (timerRef.current) clearInterval(timerRef.current);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isRecording]);

  const formatTime = (seconds: number) => {
    const mins = Math.floor(seconds / 60);
    const secs = seconds % 60;
    return `${mins}:${secs < 10 ? "0" : ""}${secs}`;
  };

  return (
    <div
      className={cn(
        "flex flex-col items-center justify-center w-full transition-all duration-300 py-3",
        isRecording ? "opacity-100" : "opacity-0 h-0"
      )}
    >
      <div className="flex items-center gap-2 mb-3">
        <div className="w-2 h-2 rounded-full bg-destructive animate-pulse" />
        <span className="font-mono text-sm text-foreground/70">{formatTime(time)}</span>
      </div>
      <div className="w-full h-10 flex items-center justify-center gap-0.5 px-4">
        {[...Array(visualizerBars)].map((_, i) => (
          <div
            key={i}
            className="w-0.5 rounded-full bg-foreground/50 animate-pulse"
            style={{
              height: `${Math.max(15, Math.random() * 100)}%`,
              animationDelay: `${i * 0.05}s`,
              animationDuration: `${0.5 + Math.random() * 0.5}s`,
            }}
          />
        ))}
      </div>
    </div>
  );
};

// ImagePreview Component
interface ImagePreviewProps {
  imagePreview: string | null;
  onRemove: () => void;
}
const ImagePreview: React.FC<ImagePreviewProps> = ({ imagePreview, onRemove }) => {
  const [isDialogOpen, setIsDialogOpen] = React.useState(false);
  if (!imagePreview) return null;
  return (
    <div className="relative mb-1 w-fit rounded-xl px-1 pt-1">
      <button
        type="button"
        className="transition-transform"
        onClick={() => setIsDialogOpen(true)}
      >
        <img
          src={imagePreview}
          alt="Preview"
          className="h-14.5 w-14.5 rounded-lg object-cover"
        />
      </button>
      <button
        onClick={onRemove}
        className="absolute right-2 top-2 rounded-full bg-card/80 border border-border p-0.5 text-foreground hover:bg-accent transition-colors"
      >
        <X className="h-3.5 w-3.5" />
      </button>

      <Dialog open={isDialogOpen} onOpenChange={setIsDialogOpen}>
        <DialogContent>
          <div className="relative">
            <img
              src={imagePreview}
              alt="Full preview"
              className="w-full max-h-[80vh] object-contain rounded-2xl"
            />
            <DialogClose className="absolute right-3 top-3 rounded-full bg-card/80 border border-border p-1.5 text-foreground hover:bg-accent transition-colors">
              <X className="h-5 w-5" />
            </DialogClose>
          </div>
        </DialogContent>
      </Dialog>
    </div>
  );
};

// PromptInput Context and Components
interface PromptInputContextType {
  isLoading: boolean;
  value: string;
  setValue: (value: string) => void;
  maxHeight: number | string;
  onSubmit?: () => void;
  disabled?: boolean;
}
const PromptInputContext = React.createContext<PromptInputContextType>({
  isLoading: false,
  value: "",
  setValue: () => {},
  maxHeight: 240,
  onSubmit: undefined,
  disabled: false,
});
function usePromptInput() {
  const context = React.useContext(PromptInputContext);
  if (!context) throw new Error("usePromptInput must be used within a PromptInput");
  return context;
}

interface PromptInputProps {
  isLoading?: boolean;
  value?: string;
  onValueChange?: (value: string) => void;
  maxHeight?: number | string;
  onSubmit?: () => void;
  children: React.ReactNode;
  className?: string;
  disabled?: boolean;
  onDragOver?: (e: React.DragEvent) => void;
  onDragLeave?: (e: React.DragEvent) => void;
  onDrop?: (e: React.DragEvent) => void;
}
const PromptInput = React.forwardRef<HTMLDivElement, PromptInputProps>(
  (
    {
      className,
      isLoading = false,
      maxHeight = 240,
      value,
      onValueChange,
      onSubmit,
      children,
      disabled = false,
      onDragOver,
      onDragLeave,
      onDrop,
    },
    ref
  ) => {
    const [internalValue, setInternalValue] = React.useState(value || "");
    const handleChange = (newValue: string) => {
      setInternalValue(newValue);
      onValueChange?.(newValue);
    };
    return (
      <TooltipProvider>
        <PromptInputContext.Provider
          value={{
            isLoading,
            value: value ?? internalValue,
            setValue: onValueChange ?? handleChange,
            maxHeight,
            onSubmit,
            disabled,
          }}
        >
          <div
            ref={ref}
            className={cn(
              "rounded-3xl border border-border bg-card p-2 shadow-sm transition-all duration-300",
              isLoading && "border-ring/50",
              className
            )}
            onDragOver={onDragOver}
            onDragLeave={onDragLeave}
            onDrop={onDrop}
          >
            {children}
          </div>
        </PromptInputContext.Provider>
      </TooltipProvider>
    );
  }
);
PromptInput.displayName = "PromptInput";

interface PromptInputTextareaProps {
  disableAutosize?: boolean;
  placeholder?: string;
}
const PromptInputTextarea: React.FC<PromptInputTextareaProps & React.TextareaHTMLAttributes<HTMLTextAreaElement>> = ({
  className,
  onKeyDown,
  disableAutosize = false,
  placeholder,
  ...props
}) => {
  const { value, setValue, maxHeight, onSubmit, disabled } = usePromptInput();
  const textareaRef = React.useRef<HTMLTextAreaElement>(null);

  React.useEffect(() => {
    if (disableAutosize || !textareaRef.current) return;
    textareaRef.current.style.height = "auto";
    textareaRef.current.style.height =
      typeof maxHeight === "number"
        ? `${Math.min(textareaRef.current.scrollHeight, maxHeight)}px`
        : `min(${textareaRef.current.scrollHeight}px, ${maxHeight})`;
  }, [value, maxHeight, disableAutosize]);

  const handleKeyDown = (e: React.KeyboardEvent<HTMLTextAreaElement>) => {
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      onSubmit?.();
    }
    onKeyDown?.(e);
  };

  return (
    <Textarea
      ref={textareaRef}
      value={value}
      onChange={(e) => setValue(e.target.value)}
      onKeyDown={handleKeyDown}
      className={cn(
        "text-base promptbox-scroll",
        className
      )}
      disabled={disabled}
      placeholder={placeholder}
      {...props}
    />
  );
};

interface PromptInputActionsProps extends React.HTMLAttributes<HTMLDivElement> {}
const PromptInputActions: React.FC<PromptInputActionsProps> = ({ children, className, ...props }) => (
  <div className={cn("flex items-center gap-2", className)} {...props}>
    {children}
  </div>
);

interface PromptInputActionProps extends React.ComponentProps<typeof Tooltip> {
  tooltip: React.ReactNode;
  children: React.ReactNode;
  side?: "top" | "bottom" | "left" | "right";
  className?: string;
}
const PromptInputAction: React.FC<PromptInputActionProps> = ({
  tooltip,
  children,
  className,
  side = "top",
  ...props
}) => {
  const { disabled } = usePromptInput();
  return (
    <Tooltip {...props}>
      <TooltipTrigger asChild disabled={disabled}>
        {children}
      </TooltipTrigger>
      <TooltipContent
        side={side}
        className={cn(
          "z-50 overflow-hidden rounded-md border border-border bg-card px-3 py-1.5 text-xs text-foreground shadow-md",
          className
        )}
      >
        {tooltip}
      </TooltipContent>
    </Tooltip>
  );
};

// Custom Divider Component
const CustomDivider: React.FC = () => (
  <div className="relative h-6 w-[1.5px] mx-1">
    <div className="absolute inset-0 bg-border rounded-full" />
  </div>
);

// Main PromptInputBox Component
interface PromptInputBoxProps {
  onSend?: (message: string, files?: File[]) => void;
  isLoading?: boolean;
  placeholder?: string;
  className?: string;
}
export const PromptInputBox = React.forwardRef<HTMLDivElement, PromptInputBoxProps>((props, ref) => {
  const { onSend = () => {}, isLoading = false, placeholder = "Type your message here...", className } = props;
  const [input, setInput] = React.useState("");
  const [files, setFiles] = React.useState<File[]>([]);
  const [filePreviews, setFilePreviews] = React.useState<{ [key: string]: string }>({});
  const [showSearch, setShowSearch] = React.useState(false);
  const [showThink, setShowThink] = React.useState(false);
  const [showCanvas, setShowCanvas] = React.useState(false);
  const [isRecording, setIsRecording] = React.useState(false);
  const uploadInputRef = React.useRef<HTMLInputElement>(null);
  const promptBoxRef = React.useRef<HTMLDivElement>(null);

  const isImageFile = (file: File) => file.type.startsWith("image/");

  const processFile = (file: File) => {
    if (!isImageFile(file)) {
      console.log("Only image files are allowed");
      return;
    }
    if (file.size > 10 * 1024 * 1024) {
      console.log("File too large (max 10MB)");
      return;
    }
    setFiles([file]);
    const reader = new FileReader();
    reader.onload = (e) => {
      const result = e.target?.result as string;
      setFilePreviews({ [file.name]: result });
    };
    reader.readAsDataURL(file);
  };

  const handleDragOver = React.useCallback((e: React.DragEvent) => {
    e.preventDefault();
  }, []);
  const handleDragLeave = React.useCallback((e: React.DragEvent) => {
    e.preventDefault();
  }, []);
  const handleDrop = React.useCallback((e: React.DragEvent) => {
    e.preventDefault();
    const droppedFiles = Array.from(e.dataTransfer.files);
    const imageFiles = droppedFiles.filter((file) => isImageFile(file));
    if (imageFiles.length > 0) processFile(imageFiles[0]);
  }, []);

  const handleRemoveFile = (index: number) => {
    const fileToRemove = files[index];
    if (fileToRemove && filePreviews[fileToRemove.name]) {
      const newPreviews = { ...filePreviews };
      delete newPreviews[fileToRemove.name];
      setFilePreviews(newPreviews);
    }
    setFiles([]);
  };

  const handlePaste = React.useCallback((e: React.ClipboardEvent) => {
    const items = e.clipboardData?.items;
    if (!items) return;
    for (let i = 0; i < items.length; i++) {
      if (items[i].type.indexOf("image") !== -1) {
        const file = items[i].getAsFile();
        if (file) {
          e.preventDefault();
          processFile(file);
          break;
        }
      }
    }
  }, []);

  const handleSubmit = () => {
    if (input.trim() || files.length > 0) {
      onSend(input, files);
      setInput("");
      setFiles([]);
      setFilePreviews({});
    }
  };

  const handleStartRecording = () => console.log("Started recording");
  const handleStopRecording = (duration: number) => {
    console.log(`Stopped recording after ${duration} seconds`);
    setIsRecording(false);
    onSend(`[Voice message - ${duration} seconds]`, []);
  };

  const hasContent = input.trim() !== "" || files.length > 0;

  return (
    <PromptInput
      value={input}
      onValueChange={setInput}
      isLoading={isLoading}
      onSubmit={handleSubmit}
      className={cn("w-full bg-card border-border shadow-sm transition-all duration-300 ease-in-out", isRecording && "border-destructive/50", className)}
      disabled={isLoading || isRecording}
      ref={ref || promptBoxRef}
      onDragOver={handleDragOver}
      onDragLeave={handleDragLeave}
      onDrop={handleDrop}
    >
      {files.length > 0 && !isRecording && (
        <div className="flex flex-wrap gap-2 p-0 pb-1 transition-all duration-300">
          {files.map((file, index) => (
            <div key={index}>
              {isImageFile(file) && (
                <ImagePreview
                  imagePreview={filePreviews[file.name]}
                  onRemove={() => handleRemoveFile(index)}
                />
              )}
            </div>
          ))}
        </div>
      )}

      <div
        className={cn(
          "transition-all duration-300",
          isRecording ? "h-0 overflow-hidden opacity-0" : "opacity-100"
        )}
      >
        <PromptInputTextarea
          placeholder={
            showSearch
              ? "Search the web..."
              : showThink
              ? "Think deeply..."
              : showCanvas
              ? "Create on canvas..."
              : placeholder
          }
          className="text-base"
          onPaste={handlePaste}
        />
      </div>

      {isRecording && (
        <VoiceRecorder
          isRecording={isRecording}
          onStartRecording={handleStartRecording}
          onStopRecording={handleStopRecording}
        />
      )}

      <PromptInputActions className="flex items-center justify-between gap-2 p-0 pt-2">
        <div className="flex items-center gap-1">
          <PromptInputAction tooltip="Upload image">
            <button
              type="button"
              onClick={() => uploadInputRef.current?.click()}
              className="flex h-8 w-8 items-center justify-center rounded-full text-muted-foreground hover:bg-accent hover:text-accent-foreground transition-colors"
              disabled={isRecording}
            >
              <Paperclip className="h-5 w-5 transition-colors" />
              <input
                ref={uploadInputRef}
                type="file"
                className="hidden"
                onChange={(e) => {
                  if (e.target.files && e.target.files.length > 0) {
                    processFile(e.target.files[0]);
                  }
                  if (e.target) e.target.value = "";
                }}
                accept="image/*"
              />
            </button>
          </PromptInputAction>

          <button
            type="button"
            onClick={() => {
              setShowSearch((prev) => !prev);
              setShowThink(false);
              setShowCanvas(false);
            }}
            className={cn(
              "flex h-8 items-center gap-2 rounded-full px-2 text-sm transition-colors",
              showSearch
                ? "bg-accent text-foreground border border-border"
                : "text-muted-foreground hover:bg-accent hover:text-accent-foreground"
            )}
          >
            <div className="flex h-5 w-5 items-center justify-center flex-shrink-0">
              <motion.div
                animate={{ rotate: showSearch ? 180 : 0, scale: showSearch ? 1.1 : 1 }}
                whileHover={{ rotate: showSearch ? 180 : 15, scale: 1.1 }}
                transition={{ type: "spring", stiffness: 260, damping: 25 }}
              >
                <Globe className="h-4 w-4" />
              </motion.div>
            </div>
            <AnimatePresence>
              {showSearch && (
                <motion.span
                  initial={{ width: 0, opacity: 0 }}
                  animate={{ width: "auto", opacity: 1 }}
                  exit={{ width: 0, opacity: 0 }}
                  transition={{ duration: 0.2 }}
                  className="overflow-hidden whitespace-nowrap"
                >
                  Search
                </motion.span>
              )}
            </AnimatePresence>
          </button>

          <button
            type="button"
            onClick={() => {
              setShowThink((prev) => !prev);
              setShowSearch(false);
              setShowCanvas(false);
            }}
            className={cn(
              "flex h-8 items-center gap-2 rounded-full px-2 text-sm transition-colors",
              showThink
                ? "bg-accent text-foreground border border-border"
                : "text-muted-foreground hover:bg-accent hover:text-accent-foreground"
            )}
          >
            <div className="flex h-5 w-5 items-center justify-center flex-shrink-0">
              <motion.div
                animate={{ rotate: showThink ? 360 : 0, scale: showThink ? 1.1 : 1 }}
                whileHover={{ rotate: 360, scale: 1.1 }}
                transition={{ type: "spring", stiffness: 260, damping: 25 }}
              >
                <BrainCog className="h-4 w-4" />
              </motion.div>
            </div>
            <AnimatePresence>
              {showThink && (
                <motion.span
                  initial={{ width: 0, opacity: 0 }}
                  animate={{ width: "auto", opacity: 1 }}
                  exit={{ width: 0, opacity: 0 }}
                  transition={{ duration: 0.2 }}
                  className="overflow-hidden whitespace-nowrap"
                >
                  Think
                </motion.span>
              )}
            </AnimatePresence>
          </button>

          <CustomDivider />

          <button
            type="button"
            onClick={() => {
              setShowCanvas((prev) => !prev);
              setShowSearch(false);
              setShowThink(false);
            }}
            className={cn(
              "flex h-8 items-center gap-2 rounded-full px-2 text-sm transition-colors",
              showCanvas
                ? "bg-accent text-foreground border border-border"
                : "text-muted-foreground hover:bg-accent hover:text-accent-foreground"
            )}
          >
            <div className="flex h-5 w-5 items-center justify-center flex-shrink-0">
              <motion.div
                animate={{ rotate: showCanvas ? 360 : 0, scale: showCanvas ? 1.1 : 1 }}
                whileHover={{ rotate: showCanvas ? 360 : 15, scale: 1.1 }}
                transition={{ type: "spring", stiffness: 260, damping: 25 }}
              >
                <FolderCode className="h-4 w-4" />
              </motion.div>
            </div>
            <AnimatePresence>
              {showCanvas && (
                <motion.span
                  initial={{ width: 0, opacity: 0 }}
                  animate={{ width: "auto", opacity: 1 }}
                  exit={{ width: 0, opacity: 0 }}
                  transition={{ duration: 0.2 }}
                  className="overflow-hidden whitespace-nowrap"
                >
                  Canvas
                </motion.span>
              )}
            </AnimatePresence>
          </button>
        </div>

        <PromptInputAction
          tooltip={
            isLoading
              ? "Stop generation"
              : isRecording
              ? "Stop recording"
              : hasContent
              ? "Send message"
              : "Voice message"
          }
        >
          <Button
            variant="default"
            size="icon"
            className={cn(
              "h-8 w-8 rounded-full transition-all duration-200",
              isRecording
                ? "bg-destructive/10 text-destructive hover:bg-destructive/20"
                : hasContent
                ? "bg-primary text-primary-foreground hover:bg-primary/90"
                : "bg-transparent text-muted-foreground hover:bg-accent hover:text-accent-foreground"
            )}
            onClick={() => {
              if (isLoading) {
                // Stop-generation wiring is supplied by the active run controller.
              } else if (isRecording) {
                setIsRecording(false);
              } else if (hasContent) {
                handleSubmit();
              } else {
                setIsRecording(true);
              }
            }}
          >
            {isLoading ? (
              <Square className="h-4 w-4 fill-current animate-pulse" />
            ) : isRecording ? (
              <Square className="h-4 w-4 fill-current" />
            ) : hasContent ? (
              <ArrowUp className="h-4 w-4" />
            ) : (
              <Mic className="h-5 w-5 transition-colors" />
            )}
          </Button>
        </PromptInputAction>
      </PromptInputActions>
    </PromptInput>
  );
});
PromptInputBox.displayName = "PromptInputBox";

// touch: trigger jac watcher copy
