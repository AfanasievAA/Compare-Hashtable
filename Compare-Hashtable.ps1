<#
.SYNOPSIS
Compare two Hashtable and returns an array of differences.
.DESCRIPTION
The Compare-Hashtable function computes differences between two Hashtables. Results are returned as
an array of objects with the properties: "key" (the name of the key that caused a difference),
"side" (one of "<=", "!=" or "=>"), "lvalue" and "rvalue" (resp. the left and right value
associated with the key).
The comparison core is a precompiled C# engine (Add-Type), which is orders of magnitude faster
on large tables than a pure PowerShell implementation.
.PARAMETER left
The left hand side Hashtable (any IDictionary) to compare.
.PARAMETER right
The right hand side Hashtable (any IDictionary) to compare.
.PARAMETER PropertyName
If set - compare procedure will use only this object property to compare HashTables
For example this could be MD5 hash of some other object properties
.PARAMETER outputValueName
If set - will include in array of differences specified property.
For example when comparing using MD5SUM it is useful to include other properties in array of differences to operate with
.EXAMPLE
Returns a difference for a (1 "<="), c (3 "!=" 4) and e ("=>" 5).
Compare-Hashtable @{ a = 1; b = 2; c = 3 } @{ b = 2; c = 4; e = 5}
.EXAMPLE
Returns a difference for a (1 "<="), c (3 "!=" 4), e ("=>" 5) and g (6 "!=" $Null).
 $left = @{ a = 1; b = 2; c = 3; f = $Null; g = 6 }
 $right = @{ b = 2; c = 4; e = 5; f = $Null; g = $Null }
Compare-Hashtable $left $right
.NOTES
Value equality: strings are compared case-insensitively (ordinal); byte[] and arrays are compared
element-wise; numeric values of different types are unified (3 -eq 3.0). Mixed pairs like 1 and "1"
are treated as different values (no PowerShell type coercion).
  Version:        1.68
  Author:         Andrew Afanasiev
  Date:           30 Sep 2026
  Contacts:       AfanasievAA@yandex.ru

#>

# Compile the native comparison engine once per session (idempotent, ~0.1-0.3 s first time)
if (-not ('FastCompare.HashtableDiff' -as [type])) {
    # The list below is only used on Windows PowerShell 5.1 (see the compile step).
    # -ReferencedAssemblies REPLACES the default reference set, so the list must be complete.
    # The BCL is split across runtime assemblies (System.Private.CoreLib, System.Collections,
    # System.Runtime, ...) and the split differs between .NET versions. Resolving the DEFINING
    # assembly of every type used by the engine makes the list correct everywhere:
    # Windows PowerShell 5.1 (CodeDom/GAC).
    $assemblies = @(
        [System.Object].Assembly.Location
        [System.Type].Assembly.Location
        [System.StringComparison].Assembly.Location
        [System.TypeCode].Assembly.Location
        [System.Convert].Assembly.Location
        [System.IConvertible].Assembly.Location
        [System.StringComparer].Assembly.Location
        [System.Func[string, object]].Assembly.Location
        [System.Globalization.CultureInfo].Assembly.Location
        [System.Collections.IDictionary].Assembly.Location
        [System.Collections.DictionaryEntry].Assembly.Location
        [System.Collections.IList].Assembly.Location
        [System.Collections.Generic.List[string]].Assembly.Location
        [System.Collections.Generic.Dictionary[string, string]].Assembly.Location
        [System.Collections.Concurrent.ConcurrentDictionary[string, int]].Assembly.Location
        [System.Reflection.PropertyInfo].Assembly.Location
        [System.Reflection.BindingFlags].Assembly.Location
        [System.Linq.Expressions.Expression].Assembly.Location
        [System.Linq.Expressions.ParameterExpression].Assembly.Location
        [System.Management.Automation.PSObject].Assembly.Location
        [System.Management.Automation.PSPropertyInfo].Assembly.Location
    ) | Where-Object { $_ } | Sort-Object -Unique
    $src = @'
using System;
using System.Collections;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Globalization;
using System.Linq.Expressions;
using System.Management.Automation;
using System.Reflection;

namespace FastCompare
{
    // Result row: property names kept lowercase to match the original PowerShell output
    public sealed class DiffResult
    {
        public object key { get; set; }
        public object lvalue { get; set; }
        public object rvalue { get; set; }
        public string side { get; set; }
    }

    public static class HashtableDiff
    {
        // Per-type cache of compiled property getters, keyed by property name (case-insensitive).
        // Maps are built atomically and never mutated after publication -> safe concurrent reads.
        private static readonly ConcurrentDictionary<Type, Dictionary<string, Func<object, object>>> _getters =
            new ConcurrentDictionary<Type, Dictionary<string, Func<object, object>>>();

        public static List<DiffResult> Compare(IDictionary left, IDictionary right, string propertyName, string outputValueName)
        {
            List<DiffResult> results = new List<DiffResult>((left == null ? 0 : left.Count) + (right == null ? 0 : right.Count));
            if (ReferenceEquals(left, right)) return results;
            bool useProp = !string.IsNullOrEmpty(propertyName);
            bool useOut = !string.IsNullOrEmpty(outputValueName);
            if (left != null)
            {
                foreach (DictionaryEntry e in left)
                {
                    if (right != null && right.Contains(e.Key))
                    {
                        object l = e.Value;
                        object r = right[e.Key];
                        bool equal = useProp
                            ? ValuesEqual(GetMember(l, propertyName), GetMember(r, propertyName))
                            : ValuesEqual(l, r);
                        if (!equal)
                        {
                            if (useOut) { l = GetMember(l, outputValueName); r = GetMember(r, outputValueName); }
                            results.Add(new DiffResult { key = e.Key, lvalue = l, rvalue = r, side = "!=" });
                        }
                    }
                    else
                    {
                        results.Add(new DiffResult { key = e.Key, lvalue = useOut ? GetMember(e.Value, outputValueName) : e.Value, rvalue = null, side = "<=" });
                    }
                }
            }
            if (right != null)
            {
                foreach (DictionaryEntry e in right)
                {
                    if (left == null || !left.Contains(e.Key))
                    {
                        results.Add(new DiffResult { key = e.Key, lvalue = null, rvalue = useOut ? GetMember(e.Value, outputValueName) : e.Value, side = "=>" });
                    }
                }
            }
            return results;
        }

        // PowerShell-compatible value equality, fast paths first, no LanguagePrimitives involved
        private static bool ValuesEqual(object a, object b)
        {
            if (a == null) return b == null;
            if (b == null) return false;
            if (ReferenceEquals(a, b)) return true;
            string sa = a as string;
            if (sa != null)
            {
                string sb = b as string;
                return sb != null && string.Equals(sa, sb, StringComparison.OrdinalIgnoreCase);
            }
            if (a.Equals(b)) return true;            // scalars, dates, guids, same-type numbers
            byte[] ba = a as byte[];                 // file hashes (Get-FileHash) are byte[]
            if (ba != null)
            {
                byte[] bb = b as byte[];
                if (bb == null || ba.Length != bb.Length) return false;
                for (int i = 0; i < ba.Length; i++) if (ba[i] != bb[i]) return false;
                return true;
            }
            IList la = a as IList;                   // sequences: element-wise equality
            if (la != null)
            {
                IList lb = b as IList;
                if (lb == null || la.Count != lb.Count) return false;
                for (int i = 0; i < la.Count; i++) if (!ValuesEqual(la[i], lb[i])) return false;
                return true;
            }
            // numeric unification like PowerShell: 3 -eq 3.0
            IConvertible ca = a as IConvertible;
            IConvertible cb = b as IConvertible;
            if (ca != null && cb != null && IsNumeric(ca) && IsNumeric(cb))
                return Convert.ToDouble(ca, CultureInfo.InvariantCulture) == Convert.ToDouble(cb, CultureInfo.InvariantCulture);
            return false;
        }

        private static bool IsNumeric(IConvertible c)
        {
            switch (c.GetTypeCode())
            {
                case TypeCode.Byte: case TypeCode.SByte:
                case TypeCode.Int16: case TypeCode.UInt16:
                case TypeCode.Int32: case TypeCode.UInt32:
                case TypeCode.Int64: case TypeCode.UInt64:
                case TypeCode.Single: case TypeCode.Double: case TypeCode.Decimal:
                    return true;
                default:
                    return false;
            }
        }

        // Dynamic member access: PSObject members first, then compiled CLR getters,
        // then the PowerShell adapter layer (adapted/ETS members, e.g. FileInfo.Mode)
        private static object GetMember(object obj, string name)
        {
            if (obj == null) return null;
            try
            {
                PSObject ps = obj as PSObject;
                if (ps != null)
                {
                    PSPropertyInfo p = ps.Properties[name];
                    return p != null ? p.Value : null;
                }
                Dictionary<string, Func<object, object>> map = _getters.GetOrAdd(obj.GetType(), BuildGetterMap);
                Func<object, object> getter;
                if (map.TryGetValue(name, out getter)) return getter(obj);
                PSPropertyInfo fallback = PSObject.AsPSObject(obj).Properties[name];
                return fallback != null ? fallback.Value : null;
            }
            catch
            {
                return null; // a failing getter behaves like PowerShell: the value is treated as null
            }
        }

        private static Dictionary<string, Func<object, object>> BuildGetterMap(Type t)
        {
            Dictionary<string, Func<object, object>> map = new Dictionary<string, Func<object, object>>(StringComparer.OrdinalIgnoreCase);
            PropertyInfo[] props = t.GetProperties(BindingFlags.Public | BindingFlags.Instance);
            for (int i = 0; i < props.Length; i++)
            {
                PropertyInfo pi = props[i];
                if (!pi.CanRead || pi.GetIndexParameters().Length > 0 || map.ContainsKey(pi.Name)) continue;
                map.Add(pi.Name, BuildGetter(pi));
            }
            return map;
        }

        private static Func<object, object> BuildGetter(PropertyInfo pi)
        {
            ParameterExpression p = Expression.Parameter(typeof(object), "o");
            Expression body = Expression.Convert(Expression.Property(Expression.Convert(p, pi.DeclaringType), pi), typeof(object));
            return Expression.Lambda<Func<object, object>>(body, p).Compile();
        }
    }
}
'@
    if ($PSVersionTable.PSEdition -eq 'Core') {
        # PowerShell 7+: keep the DEFAULT reference set of Add-Type. It already contains
        # System.Private.CoreLib, System.Collections, System.Linq.Expressions and
        # System.Management.Automation. Replacing it with a hand-built list of runtime
        # DLLs loses System.Private.CoreLib on .NET 10 (type split across runtime
        # assemblies changed) and fails with CS0246/CS0012 for List<>/Dictionary<>/Func<>.
        Add-Type -TypeDefinition $src
    } else {
        # Windows PowerShell 5.1: default references are only mscorlib/System/System.Core,
        # so an explicit complete list is required (incl. System.Management.Automation).
        Add-Type -ReferencedAssemblies $assemblies -TypeDefinition $src
    }
}

Function Compare-Hashtable ([System.Collections.IDictionary]$Left, [System.Collections.IDictionary]$Right, [string]$propertyName, [string]$outputValueName) {
    return ,([FastCompare.HashtableDiff]::Compare($Left, $Right, $propertyName, $outputValueName))
}