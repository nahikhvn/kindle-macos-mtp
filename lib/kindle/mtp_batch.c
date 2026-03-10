/*
 * mtp-batch — single-session MTP tool for Kindle on macOS
 *
 * Subcommands:
 *   detect                         Check for connected device
 *   scan  <cache_dir> [targets...] List all files + pull named targets
 *   get   <file_id> <dest>         Download one file by ID
 *   send  <file> [parent_id]       Upload a file
 *   rm    <file_id>                Delete a file
 *   books <dest_dir>               Download all book files
 *
 * Every subcommand opens ONE MTP session — no replugging needed.
 */

#include <libmtp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>

#define MAX_MATCH 32

static LIBMTP_mtpdevice_t *open_device(void) {
    LIBMTP_Init();
    return LIBMTP_Get_First_Device();
}

/* detect — print device info */
static int do_detect(LIBMTP_mtpdevice_t *dev) {
    char *name = LIBMTP_Get_Friendlyname(dev);
    char *model = LIBMTP_Get_Modelname(dev);
    char *serial = LIBMTP_Get_Serialnumber(dev);
    printf("name|%s\n", name ? name : "");
    printf("model|%s\n", model ? model : "");
    printf("serial|%s\n", serial ? serial : "");
    free(name); free(model); free(serial);
    return 0;
}

/* scan — list all files (stdout) + pull named targets to cache_dir (stderr) */
static int do_scan(LIBMTP_mtpdevice_t *dev, int argc, char **argv) {
    if (argc < 1) {
        fprintf(stderr, "Usage: mtp-batch scan <cache_dir> [target ...]\n");
        return 1;
    }
    const char *cache_dir = argv[0];
    int ntargets = argc - 1;
    char *targets[MAX_MATCH];
    for (int i = 0; i < ntargets && i < MAX_MATCH; i++)
        targets[i] = argv[i + 1];

    LIBMTP_file_t *files = LIBMTP_Get_Filelisting_With_Callback(dev, NULL, NULL);

    struct { uint32_t id; char name[256]; } matches[MAX_MATCH];
    int nmatch = 0;

    for (LIBMTP_file_t *f = files; f; f = f->next) {
        printf("%u|%s|%llu\n", f->item_id, f->filename,
               (unsigned long long)f->filesize);
        for (int i = 0; i < ntargets && i < MAX_MATCH; i++) {
            if (targets[i] && strcasecmp(f->filename, targets[i]) == 0) {
                matches[nmatch].id = f->item_id;
                strncpy(matches[nmatch].name, f->filename, 255);
                matches[nmatch].name[255] = '\0';
                nmatch++;
                targets[i] = NULL;
                break;
            }
        }
    }
    while (files) {
        LIBMTP_file_t *tmp = files;
        files = files->next;
        LIBMTP_destroy_file_t(tmp);
    }

    for (int i = 0; i < nmatch; i++) {
        char dest[4096];
        snprintf(dest, sizeof(dest), "%s/%s", cache_dir, matches[i].name);
        fprintf(stderr, "  Pulling %s... ", matches[i].name);
        if (LIBMTP_Get_File_To_File(dev, matches[i].id, dest, NULL, NULL) == 0)
            fprintf(stderr, "ok\n");
        else {
            fprintf(stderr, "failed\n");
            remove(dest);
        }
    }
    return 0;
}

/* get — download one file by MTP ID */
static int do_get(LIBMTP_mtpdevice_t *dev, int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "Usage: mtp-batch get <file_id> <dest>\n");
        return 1;
    }
    uint32_t id = (uint32_t)atoi(argv[0]);
    const char *dest = argv[1];
    if (LIBMTP_Get_File_To_File(dev, id, dest, NULL, NULL) == 0)
        return 0;
    remove(dest);
    return 1;
}

/* send — upload a file to the device */
static int do_send(LIBMTP_mtpdevice_t *dev, int argc, char **argv) {
    if (argc < 1) {
        fprintf(stderr, "Usage: mtp-batch send <file> [parent_id]\n");
        return 1;
    }
    const char *filepath = argv[0];
    uint32_t parent = (argc > 1) ? (uint32_t)atoi(argv[1]) : 0;

    struct stat st;
    if (stat(filepath, &st) != 0) {
        fprintf(stderr, "Cannot stat %s\n", filepath);
        return 1;
    }

    const char *fname = strrchr(filepath, '/');
    fname = fname ? fname + 1 : filepath;

    LIBMTP_file_t *file = LIBMTP_new_file_t();
    file->filesize = st.st_size;
    file->filename = strdup(fname);
    file->filetype = LIBMTP_FILETYPE_UNKNOWN;
    file->parent_id = parent;
    file->storage_id = 0;

    int ret = LIBMTP_Send_File_From_File(dev, filepath, file, NULL, NULL);
    LIBMTP_destroy_file_t(file);
    return ret;
}

/* rm — delete a file by MTP ID */
static int do_rm(LIBMTP_mtpdevice_t *dev, int argc, char **argv) {
    if (argc < 1) {
        fprintf(stderr, "Usage: mtp-batch rm <file_id>\n");
        return 1;
    }
    uint32_t id = (uint32_t)atoi(argv[0]);
    return LIBMTP_Delete_Object(dev, id);
}

/* books — find and download all book files in one session */
static int do_books(LIBMTP_mtpdevice_t *dev, int argc, char **argv) {
    if (argc < 1) {
        fprintf(stderr, "Usage: mtp-batch books <dest_dir>\n");
        return 1;
    }
    const char *dest_dir = argv[0];

    LIBMTP_file_t *files = LIBMTP_Get_Filelisting_With_Callback(dev, NULL, NULL);
    int count = 0;

    for (LIBMTP_file_t *f = files; f; f = f->next) {
        const char *ext = strrchr(f->filename, '.');
        if (!ext) continue;
        if (strcasecmp(ext, ".kfx") == 0 || strcasecmp(ext, ".mobi") == 0 ||
            strcasecmp(ext, ".pdf") == 0 || strcasecmp(ext, ".epub") == 0) {
            char dest[4096];
            snprintf(dest, sizeof(dest), "%s/%s", dest_dir, f->filename);
            fprintf(stderr, "  Pulling %s... ", f->filename);
            if (LIBMTP_Get_File_To_File(dev, f->item_id, dest, NULL, NULL) == 0) {
                fprintf(stderr, "ok\n");
                count++;
            } else {
                fprintf(stderr, "failed\n");
                remove(dest);
            }
        }
    }
    while (files) {
        LIBMTP_file_t *tmp = files;
        files = files->next;
        LIBMTP_destroy_file_t(tmp);
    }
    fprintf(stderr, "  Downloaded %d book(s)\n", count);
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "Usage: mtp-batch <command> [args...]\n"
                        "Commands: detect, scan, get, send, rm, books\n");
        return 1;
    }

    const char *cmd = argv[1];
    LIBMTP_mtpdevice_t *dev = open_device();
    if (!dev) {
        fprintf(stderr, "No MTP devices found.\n");
        return 1;
    }

    int ret;
    if      (strcmp(cmd, "detect") == 0) ret = do_detect(dev);
    else if (strcmp(cmd, "scan")   == 0) ret = do_scan(dev, argc - 2, argv + 2);
    else if (strcmp(cmd, "get")    == 0) ret = do_get(dev, argc - 2, argv + 2);
    else if (strcmp(cmd, "send")   == 0) ret = do_send(dev, argc - 2, argv + 2);
    else if (strcmp(cmd, "rm")     == 0) ret = do_rm(dev, argc - 2, argv + 2);
    else if (strcmp(cmd, "books")  == 0) ret = do_books(dev, argc - 2, argv + 2);
    else {
        fprintf(stderr, "Unknown command: %s\n", cmd);
        ret = 1;
    }

    LIBMTP_Release_Device(dev);
    return ret;
}
